(defsystem "image-classifier"
  :version "0.1.0"
  :author ""
  :license ""
  :depends-on ("dexador"
               "opticl"
               "yason"
               "cl-interpol"
               "alexandria"
               "str"
               "flexi-streams"
               "clack"
               "snooze"
               "hunchentoot"
               "lparallel"
               "array-operations"
               "qbase64")
  :components ((:module "src"
                :components
                ((:file "main"))))
  :description ""
  :in-order-to ((test-op (test-op "image-classifier/tests")))
  :build-operation "program-op"
  :build-pathname "app"
  :entry-point "image-classifier;main")

(defsystem "image-classifier/tests"
  :author ""
  :license ""
  :depends-on ("image-classifier"
               "rove")
  :components ((:module "tests"
                :components
                ((:file "main"))))
  :description "Test system for image-classifier"
  :perform (test-op (op c) (symbol-call :rove :run c)))
