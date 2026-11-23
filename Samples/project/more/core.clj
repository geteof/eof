(ns demo.core
  (:require [clojure.string :as str]))

;; Greets someone
(defn greet [name]
  (if (str/blank? name)
    "Hello"
    (str "Hello, " name)))

(def ^:private max-items 3)
