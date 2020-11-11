(defpackage image-classifier
  (:use :cl)
  (:import-from :alexandria
                :hash-table-plist)
  (:import-from :yason
                :parse
                :with-output-to-string*
                :encode-plist)
  (:import-from :snooze :defroute :http-condition :payload-as-string)
  (:import-from :lparallel :make-channel :*kernel* :make-kernel :submit-task :receive-result)
  (:import-from :qbase64 :decode-string)
  (:export :start :stop :Image))
(in-package :image-classifier)

(cl-interpol:enable-interpol-syntax)

(defparameter *api-url* "http://gelbooru.me/index.php?")
(defparameter *api-creds* (uiop:getenv "IC_API_CREDS"))
(defparameter *request-timeout* 300)
(defparameter *picture-directory* (uiop:getenv "IC_PICTURE_ROOT"))

(setf lparallel:*kernel* (lparallel:make-kernel 2))


;;; Data Acquisition Functions

;; Grab Posts
(defun get-posts (tags)
  (let ((formatted-tags (format nil "~{~a~}" (mapcar (lambda (s) #?"$(s)&") tags))))
    (multiple-value-bind (body status headers)
        (dex:get #?"$(*api-url*)page=dapi&s=post&q=index&json=1&limit=100&tags=$(formatted-tags)$(*api-creds*)"
                 :connect-timeout *request-timeout*
                 :read-timeout *request-timeout*)
      (assert (= 200 status))
      body)))

;; Convert JSON Body to Hash Tables
(defun convert-json-to-hash (body)
  (yason:parse (caddr (str:split #\Newline body))))

;; Extract file_url
(defun get-file-urls (response-tables)
  (mapcar (lambda (table) (gethash "file_url" table)) response-tables))

;; Extract image name
(defun get-image-name (response-table) (gethash "image" response-table))

;; Extract image extension
(defun get-image-extension (response-table) (str:unlines (cdr (str:split "." (gethash "image" response-table)))))

;; Grab image
(defun get-image (file-url)
  (multiple-value-bind (body status headers)
      (dex:get file-url
               :force-binary t
               :connect-timeout *request-timeout*
               :read-timeout *request-timeout*)
    (assert (= 200 status))
    body))

;; Write to file
(defun write-image-to-file (image-request image-name image-extension tag-directory)
    (with-open-stream (stream (flexi-streams:make-in-memory-input-stream image-request))
      (let ((image (opticl:read-image-stream stream (intern (string-upcase image-extension) :keyword))))
        (opticl:write-image-file #?"$(tag-directory)$(image-name)" (opticl:resize-image image 32 32)))))

(defun collate-image-information (tables tag-directory)
  (mapcar (lambda (table)
            (multiple-value-bind (image-data image-name image-extension)
                (values (get-image (gethash "file_url" table)) (get-image-name table) (get-image-extension table))
              (handler-case (write-image-to-file image-data image-name image-extension tag-directory)
                (JPEG:unsupported-jpeg-format (c)
                  (format t "Bad jpeg ~a~%" (gethash "file_url" table)))
                (WINHTTP::win-error (e)
                  (format t "~a~%" e))
                (error (e)
                  (format t "~a~%" e))) 
              image-name))
          tables))

(defun collect-images (tags)
  (let* ((posts (get-posts tags))
         (tables (convert-json-to-hash posts))
         (tag-directory (format nil "~{~a~}/" (mapcar (lambda (s) #?"+$(s)") tags)))
         (tag-directory-path #?"$(*picture-directory*)$(tag-directory)"))
    (ensure-directories-exist tag-directory-path)
    (collate-image-information tables tag-directory-path)))


;;; RESTful Interface (snooze-clack-hunchentoot)

;; snooze
(defvar *handler* nil)

(defun start (&key (port 5000))
  (stop)
  (setq *handler* (clack:clackup (snooze:make-clack-app) :port port)))

(defun stop ()
  (when *handler* (clack:stop *handler*) (setq *handler* nil)))

;; One route for triggering data acquisition
(defroute download (:post "application/json")
  (let ((json (handler-case
                  (yason:parse (payload-as-string))
                 (error (e)
                   (http-condition 400 "Malformed JSON (~a)!" e))))
        (channel (make-channel)))
    (submit-task channel (lambda ()
                      (collect-images (gethash "tags" json))))
    (http-condition 200)
    (receive-result channel)))

(defroute classify (:post "application/json")
  ""
  (let ((json (handler-case
                  (parse (payload-as-string))
                (error (e)
                  (http-condition 400 "Malformed JSON (~a)!" e))))
        (channel (make-channel)))
    (submit-task channel
                 (lambda ()
                   (let ((image (make-image :features '()
                                            :data (opticl:read-image-stream
                                                   (flexi-streams:make-in-memory-input-stream (decode-string (gethash "image" json)))
                                                   (intern (string-upcase (gethash "type" json)) :keyword))
                                            :filename (gethash "name" json))))
                     (bin-features (extract-features (nearest-neighbors (gethash "k" json) image))))))
    (with-output-to-string* (:stream-symbol out)
      (encode-plist (alexandria:hash-table-plist (receive-result channel)) out))))

;;; Image Classification (K-NN)

;; Image Struct
(defstruct Image features data filename distance)

(defun image-to-alist (image)
  (pairlis (list "features" "filename" "distance")
           (list (image-features image) (namestring (image-filename image)) (image-distance image))))

;; K-NN
(defun euclidean-distance (data-points-a data-points-b)
  (sqrt (reduce #'+ (map 'vector (lambda (a b) (expt (- a b) 2)) data-points-a data-points-b))))

(defun get-image-distance (image-a image-b)
  (euclidean-distance (aops:flatten (opticl:coerce-image image-a 'opticl:8-bit-rgb-image))
                      (aops:flatten (opticl:coerce-image image-b 'opticl:8-bit-rgb-image))))

(defun calculate-image-distances (training-images test-image)
  (mapcar
   (lambda (image)
     (let ((distance (get-image-distance (image-data image)
                                         (image-data test-image))))
       (setf (image-distance image) distance)
       image))
   training-images))

(defun get-training-images ()
  (let ((directories (uiop:subdirectories *picture-directory*)))
    (mapcar
     (lambda (directory)
       (let ((tags (str:split-omit-nulls "+" (caddr (str:split-omit-nulls "/" (namestring directory)))))
             (filenames (uiop:directory-files directory)))
         (mapcar
          (lambda (filename)
            (make-image :features tags :data (opticl:read-image-file filename) :filename filename))
          filenames)))
     directories)))

(defun calculate-distances-from-training-data (unknown-image)
  (mapcar
   (lambda (images)
     (calculate-image-distances images unknown-image))
   (get-training-images)))

(defun sort-by-distance (trained-images)
  (sort (reduce #'append trained-images)
        (lambda (a b)
          (< (image-distance a)
             (image-distance b)))))

(defun nearest-neighbors (k unknown-image)
  (subseq (sort-by-distance (calculate-distances-from-training-data unknown-image)) 0 (- k 1)))

;; Feature Extraction

(defun extract-features (neighbors)
  (reduce #'append (mapcar #'image-features neighbors)))

(defun bin-features (features)
  (let ((hash (make-hash-table)))
    (mapcar (lambda (a)
              (if (gethash a hash)
                  (setf (gethash a hash) (+ 1 (gethash a hash)))
                  (setf (gethash a hash) 1)))
            features)
    hash))
