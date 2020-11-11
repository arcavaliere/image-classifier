(defpackage image-classifier/tests/main
  (:use :cl
        :image-classifier
        :rove))
(in-package :image-classifier/tests/main)

;; NOTE: To run this test file, execute `(asdf:test-system :image-classifier)' in your Lisp.

(deftest test-target-1
  (testing "should (= 1 1) to be true"
    (ok (= 1 1))))
