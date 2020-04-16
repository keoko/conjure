(module conjure.client.clojure.nrepl.action
  {require {client conjure.client
            text conjure.text
            extract conjure.extract
            editor conjure.editor
            ll conjure.linked-list
            eval conjure.aniseed.eval
            str conjure.aniseed.string
            nvim conjure.aniseed.nvim
            config conjure.client.clojure.nrepl.config
            state conjure.client.clojure.nrepl.state
            server conjure.client.clojure.nrepl.server
            ui conjure.client.clojure.nrepl.ui
            a conjure.aniseed.core}})

(defn display-session-type []
  (server.eval
    {:code (.. "#?("
               (str.join
                 " "
                 [":clj 'Clojure"
                  ":cljs 'ClojureScript"
                  ":cljr 'ClojureCLR"
                  ":default 'Unknown"])
               ")")}
    (server.with-all-msgs-fn
      (fn [msgs]
        (ui.display [(.. "; Session type: " (a.get (a.first msgs) :value))]
                    {:break? true})))))

(defn connect-port-file []
  (let [port (-?> (a.slurp ".nrepl-port") (tonumber))]
    (if port
      (server.connect
        {:host config.connection.default-host
         :port port})
      (ui.display ["; No .nrepl-port file found"]))))

(defn connect-host-port [...]
  (let [args [...]]
    (server.connect
      {:host (if (= 1 (a.count args))
               config.connection.default-host
               (a.first args))
       :port (tonumber (a.last args))})))

(defn eval-str [opts]
  (server.with-conn-or-warn
    (fn [_]
      (let [context (a.get opts :context)]
        (server.eval
          {:code (.. "(do "
                     (if context
                       (.. "(in-ns '" context ")")
                       "(in-ns #?(:clj 'user, :cljs 'cljs.user))")
                     " *1)")}
          (fn [])))
      (server.eval opts (or opts.cb #(ui.display-result opts $1))))))

(defn doc-str [opts]
  (eval-str
    (a.merge
      opts
      {:code (.. "(do (require 'clojure.repl)"
                 "    (clojure.repl/doc " opts.code "))")
       :cb (server.with-all-msgs-fn
             (fn [msgs]
               (-> msgs
                   (->> (a.map #(a.get $1 :out))
                        (a.filter a.string?)
                        (a.rest)
                        (str.join ""))
                   (text.prefixed-lines "; ")
                   (ui.display))))})))

(defn- jar->zip [path]
  (if (text.starts-with path "jar:file:")
    (string.gsub path "^jar:file:(.+)!/?(.+)$"
                 (fn [zip file]
                   (.. "zipfile:" zip "::" file)))
    path))

(defn def-str [opts]
  (eval-str
    (a.merge
      opts
      {:code (.. "(mapv #(% (meta #'" opts.code "))
      [(comp #(.toString %)
      (some-fn (comp #?(:clj clojure.java.io/resource :cljs identity)
      :file) :file))
      :line :column])")
       :cb (server.with-all-msgs-fn
             (fn [msgs]
               (let [val (a.get (a.first msgs) :value)
                     (ok? res) (when val
                                 (eval.str val))]
                 (if ok?
                   (let [[path line column] res]
                     (editor.go-to (jar->zip path) line column))
                   (ui.display ["; Couldn't find definition."])))))})))

(defn eval-file [opts]
  (server.eval
    (a.assoc opts :code (.. "(load-file \"" opts.file-path "\")"))
    #(ui.display-result opts $1)))

(defn interrupt []
  (server.with-conn-or-warn
    (fn [conn]
      (let [msgs (->> (a.vals conn.msgs)
                      (a.filter
                        (fn [msg]
                          (= :eval msg.msg.op))))]
        (if (a.empty? msgs)
          (ui.display ["; Nothing to interrupt"] {:break? true})
          (do
            (table.sort
              msgs
              (fn [a b]
                (< a.sent-at b.sent-at)))
            (let [oldest (a.first msgs)]
              (server.send {:op :interrupt
                            :id oldest.msg.id
                            :session oldest.msg.session})
              (ui.display
                [(.. "; Interrupted: "
                     (text.left-sample
                       oldest.msg.code
                       (editor.percent-width
                         config.interrupt.sample-limit)))]
                {:break? true}))))))))

(defn- eval-str-fn [code]
  (fn []
    (nvim.ex.ConjureEval code)))

(def last-exception (eval-str-fn "*e"))
(def result-1 (eval-str-fn "*1"))
(def result-2 (eval-str-fn "*2"))
(def result-3 (eval-str-fn "*3"))

(defn view-source []
  (let [word (a.get (extract.word) :content)]
    (when (not (a.empty? word))
      (ui.display [(.. "; source (word): " word)] {:break? true})
      (eval-str
        {:code (.. "(do (require 'clojure.repl)"
                   "(clojure.repl/source " word "))")
         :context (extract.context)
         :cb (server.with-all-msgs-fn
               (fn [msgs]
                 (let [source (->> msgs
                                   (a.map #(a.get $1 :out))
                                   (a.filter a.string?)
                                   (str.join ""))]
                   (ui.display
                     (text.split-lines
                       (if (= "Source not found\n" source)
                         (.. "; " source)
                         source))))))}))))

(defn clone-current-session []
  (server.with-conn-or-warn
    (fn [conn]
      (server.clone-session (a.get conn :session)))))

(defn clone-fresh-session []
  (server.with-conn-or-warn
    (fn [conn]
      (server.clone-session))))

(defn close-current-session []
  (server.with-conn-or-warn
    (fn [conn]
      (let [session (a.get conn :session)]
        (a.assoc conn :session nil)
        (ui.display [(.. "; Closed current session: " session)]
                    {:break? true})
        (server.close-session
          session server.assume-or-create-session)))))

(defn display-sessions [cb]
  (server.with-sessions
    (fn [sessions]
      (ui.display-given-sessions sessions cb))))

(defn close-all-sessions []
  (server.with-sessions
    (fn [sessions]
      (a.run! server.close-session sessions)
      (ui.display [(.. "; Closed all sessions (" (a.count sessions)")")]
                  {:break? true})
      (server.clone-session))))

(defn- cycle-session [f]
  (server.with-conn-or-warn
    (fn [conn]
      (server.with-sessions
        (fn [sessions]
          (if (= 1 (a.count sessions))
            (ui.display ["; No other sessions"] {:break? true})
            (let [session (a.get conn :session)]
              (->> sessions
                   (ll.create)
                   (ll.cycle)
                   (ll.until #(f session $1))
                   (ll.val)
                   (server.assume-session)))))))))

(defn next-session []
  (cycle-session
    (fn [current node]
      (= current (->> node (ll.prev) (ll.val))))))

(defn prev-session []
  (cycle-session
    (fn [current node]
      (= current (->> node (ll.next) (ll.val))))))

(defn select-session-interactive []
  (server.with-sessions
    (fn [sessions]
      (if (= 1 (a.count sessions))
        (ui.display ["; No other sessions"] {:break? true})
        (ui.display-given-sessions
          sessions
          (fn []
            (nvim.ex.redraw_)
            (let [n (nvim.fn.str2nr (extract.prompt "Session number: "))]
              (if (<= 1 n (a.count sessions))
                (server.assume-session (a.get sessions n))
                (ui.display ["; Invalid session number."])))))))))

;; TODO Make all of these our printers DRYer.
(defn run-all-tests []
  (ui.display ["; run-all-tests"] {:break? true})
  (server.eval
    {:code "(require 'clojure.test) (clojure.test/run-all-tests)"}
    (server.with-all-msgs-fn
      (fn [msgs]
        (-> msgs
            (->> (a.map #(a.get $1 :out))
                 (a.filter a.string?)
                 (str.join ""))
            (text.prefixed-lines "; ")
            (ui.display))))))

(defn run-ns-tests []
  (let [current-ns (extract.context)]
    (when current-ns
      (let [alt-ns (if (text.ends-with current-ns "-test")
                     (string.sub current-ns 1 -6)
                     (.. current-ns "-test"))
            nss [current-ns alt-ns]]
        (ui.display [(.. "; run-ns-tests: " (str.join ", " nss))]
                    {:break? true})
        (server.eval
          {:code (.. "(require 'clojure.test) (clojure.test/run-tests "
                     (->> nss
                          (a.map #(.. "'" $1))
                          (str.join " "))
                     ")")}
          (server.with-all-msgs-fn
            (fn [msgs]
              (-> msgs
                  (->> (a.map #(a.get $1 :out))
                       (a.filter a.string?)
                       (str.join ""))
                  (text.prefixed-lines "; ")
                  (ui.display)))))))))

(defn run-current-test [])