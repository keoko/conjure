(ns conjure.prepl
  "Remote prepl connection management and selection."
  (:require [clojure.string :as str]
            [clojure.core.async :as a]
            [clojure.core.server :as server]
            [clojure.java.io :as io]
            [clojure.edn :as edn]
            [taoensso.timbre :as log]
            [conjure.util :as util]
            [conjure.ui :as ui]
            [conjure.config :as config]
            [conjure.code :as code])
  (:import [java.io PipedInputStream PipedOutputStream IOException]))

(defonce ^:private conns! (atom {}))

(defonce internal-port
  (or (some-> (util/env :conjure-prepl-server-port)
              (edn/read-string))
      (util/free-port)))

(defn- remove!
  "Remove the connection under the given tag. Shuts it down cleanly and blocks
  until it's done."
  [tag]
  (when-let [conn (get @conns! tag)]
    (log/info "Removing" tag)
    (ui/up "Removing" tag)
    (swap! conns! dissoc tag)

    ;; read-chan is closed when the remote-prepl exits. This
    ;; pattern of closing two here and then waiting for the
    ;; read-chan to return a nil (which it will when closed)
    ;; ensures that removal isn't complete until the remote-prepl is done.
    ;; This prevents some weird race conditions with node connections.
    (let [{:keys [eval-chan ret-chan read-chan]} (:chans conn)]
      (a/close! eval-chan)
      (a/close! ret-chan)
      (loop []
        (when-not (nil? (a/<!! read-chan))
          (recur))))))

(defn- remove-all!
  "Iterate over all connections and call remove on them all."
  []
  (doseq [tag (keys @conns!)]
    (remove! tag)))

(defn- connect
  "Connect to a prepl and return channels to interact with it. When the eval
  channel closes it cascades through the system and eventually closes the read
  channel. We can use this fact to await the read channel's closure to know
  when the closing is complete. Handy!"
  [{:keys [tag host port]}]
  (let [eval-chan (a/chan 32)
        read-chan (a/chan 32)
        input (PipedInputStream.)
        output (PipedOutputStream. input)]

    (util/thread
      "reader loop"
      (with-open [reader (io/reader input)]
        (try
          (log/info "Connecting through remote-prepl" tag)
          (server/remote-prepl
            host port reader
            (fn [out]
              (log/trace "Read from remote-prepl" tag "-" (update out :form util/sample 20))
              (a/>!! read-chan out))
            :valf identity)

          (catch Throwable e
            (log/error "Error from remote-prepl:" e)
            (ui/error "Error from" tag e))

          (finally
            (log/trace "Exited remote-prepl, cleaning up" tag)
            (a/close! read-chan)
            (remove! tag)))))

    (util/thread
      "writer loop"
      (try
        (with-open [writer (io/writer output)]
          (try
            (loop []
              (when-let [code (a/<!! eval-chan)]
                (log/trace "Writing to tag:" tag "-" code)
                (util/write writer code)
                (recur)))

            (catch Throwable e
              (log/error "Error from eval-chan writing:" e))

            (finally
              (log/trace "Exited eval-chan loop, cleaning up" tag)
              (util/write writer ":repl/quit\n"))))

        (catch IOException e
          (log/error "Caught IO exception in writer thread" e))))

    {:eval-chan eval-chan
     :read-chan read-chan}))

(defn- add!
  "Remove any existing connection under :tag then create a new connection."
  [{:keys [tag lang extensions dirs exclude-path? host port]}]

  (remove! tag)

  (cond
    ;; The port was probably supposed to be read from a file with #slurp-edn
    ;; But it probably didn't exist yet.
    (nil? port)
    (ui/up "Skipping" tag "- nil port")

    ;; The socket prepl server probably isn't running.
    (not (util/socket? {:host host, :port port}))
    (ui/up "Skipping" tag "- can't connect")

    ;; Another connection exists for this host and port.
    (some
      (fn [[_tag conn]]
        (and (= host (:host conn))
             (= port (:port conn))))
      @conns!)
    (ui/up "Skipping" tag "- already connected to this host and port")

    :else
    (do
      (log/info "Adding" tag host port)
      (ui/up "Adding" tag)

      (let [ret-chan (a/chan 32)
            conn {:tag tag
                  :lang lang
                  :host host
                  :port port
                  :extensions extensions
                  :dirs dirs
                  :exclude-path? exclude-path?
                  :chans (merge
                           {:ret-chan ret-chan}
                           (connect {:tag tag
                                     :host host
                                     :port port}))}
            {:keys [eval-chan read-chan]} (get conn :chans)]

        (ui/up-start tag)
        (let [loaded-deps (when (= lang :clj)
                            (log/trace "Fetching current deps.")
                            (a/>!! eval-chan (code/render :loaded-deps {:lang lang}))
                            (-> (a/<!! read-chan)
                                (get :val)
                                (edn/read-string)))
              deps (code/render :inject-deps {:lang lang, :loaded-deps loaded-deps})]

          (let [out-of (count deps)]
            (log/trace "Evaluating" out-of "dep strings...")
            (doseq [dep deps] (a/>!! eval-chan dep))
            (doseq [n (take (count deps) (range))]
              (ui/up-progress tag (inc n) out-of)
              (a/<!! read-chan)))

          (log/trace "Deps ready!"))

        (util/thread
          "read-chan handler"
          (loop []
            (when-let [out (a/<!! read-chan)]
              (log/trace "Read value from" (:tag conn) "-" (update out :form util/sample 20))

              (if (= (:tag out) :ret)
                (a/>!! ret-chan out)
                (ui/result {:conn conn, :resp out}))

              (recur))))

        (swap! conns! assoc tag conn))

      ::added)))

(defn sync!
  "Disconnect from everything and attempt to connect to provided connection.
  Returns the tags of successful connections."
  [conns]
  (remove-all!)

  (let [results (into []
                      (comp (filter
                              (fn [[tag conn]]
                                (and (:enabled? conn)
                                     (add! (assoc conn :tag tag)))))
                            (map key))
                      conns)]
    (cond-> results
      (empty? results)
      (do
        (ui/up "Warning: No successful connections, connecting to Conjure's own JVM by default.")
        (add! (config/hydrate-conn {:tag :conjure, :port internal-port}))
        [:conjure]))))

(defn conns
  "Without a path it'll return all current connections.
  With a path a series of filters are applied to the list.
  The path will have to match a :extension and one of the :dirs.
  Finally the path will be checked against :exclude-path? if it exists for the conn."
  ([] (vals @conns!))
  ([path]
   (->> (conns)
        (filter
          (fn [{:keys [extensions dirs exclude-path?]}]
            (or (nil? path)
                (and
                  (and (some #(str/ends-with? path %) extensions)
                       (or (nil? dirs)
                           (util/path-in-dirs? path dirs)))
                  (or (nil? exclude-path?)
                      (not ((eval exclude-path?) path)))))))
        (seq))))

(defn status
  "Display the current status of the connections. This counts and lists with
  some connection information."
  []
  (let [conns (conns)
        intro (util/count-str conns "connection")
        conn-strs (for [{:keys [tag host port extensions dirs lang]} conns]
                    (str tag " @ " host ":" port
                         " for extensions " (pr-str extensions)
                         (when dirs
                           (str " and dirs " (pr-str dirs)))
                         " (" lang ")"))]
    (ui/status (util/join-lines (into [intro] conn-strs)))))

(defn init
  "Initialise the internal prepl."
  []
  (server/start-server {:accept 'clojure.core.server/io-prepl
                        :address "127.0.0.1"
                        :name :dev
                        :port internal-port})
  (log/info "Started prepl server on port" internal-port))
