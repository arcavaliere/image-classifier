(load "/home/lisp/quicklisp/setup.lisp")
(ql:quickload :image-classifier)
(sb-ext:save-lisp-and-die #P"app" :toplevel #'image-classifier:main :executable t)

