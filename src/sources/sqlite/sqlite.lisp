;;;
;;; Tools to handle the SQLite Database
;;;

(in-package :pgloader.sqlite)

(defclass copy-sqlite (db-copy)
  ((db :accessor db :initarg :db))
  (:documentation "pgloader SQLite Data Source"))

(defmethod initialize-instance :after ((source copy-sqlite) &key)
  "Add a default value for transforms in case it's not been provided."
  (let* ((transforms (when (slot-boundp source 'transforms)
		       (slot-value source 'transforms))))
    (when (and (slot-boundp source 'fields) (slot-value source 'fields))
      ;; cast typically happens in copy-database in the schema structure,
      ;; and the result is then copied into the copy-mysql instance.
      (unless (and (slot-boundp source 'columns) (slot-value source 'columns))
        (setf (slot-value source 'columns)
              (mapcar #'cast (slot-value source 'fields))))

      (unless transforms
        (setf (slot-value source 'transforms)
              (mapcar #'column-transform (slot-value source 'columns)))))))

;;; Map a function to each row extracted from SQLite
;;;
(defun sqlite-encoding (db)
  "Return a BABEL suitable encoding for the SQLite db handle."
  (let ((encoding-string (sqlite:execute-single db "pragma encoding;")))
    (cond ((string-equal encoding-string "UTF-8")    :utf-8)
          ((string-equal encoding-string "UTF-16")   :utf-16)
          ((string-equal encoding-string "UTF-16le") :utf-16le)
          ((string-equal encoding-string "UTF-16be") :utf-16be))))

(declaim (inline parse-value))

(defun parse-value (value sqlite-type pgsql-type &key (encoding :utf-8))
  "Parse value given by SQLite to match what PostgreSQL is expecting.
   In some cases SQLite will give text output for a blob column (it's
   base64) and at times will output binary data for text (utf-8 byte
   vector)."
  (cond ((and (string-equal "text" pgsql-type)
              (eq :blob sqlite-type)
              (not (stringp value)))
         ;; we expected a properly encoded string and received bytes instead
         (babel:octets-to-string value :encoding encoding))

        ((and (string-equal "bytea" pgsql-type)
              (stringp value))
         ;; we expected bytes and got a string instead, must be base64 encoded
         (base64:base64-string-to-usb8-array value))

        ;; default case, just use what's been given to us
        (t value)))

(defmethod map-rows ((sqlite copy-sqlite) &key process-row-fn)
  "Extract SQLite data and call PROCESS-ROW-FN function with a single
   argument (a list of column values) for each row"
  (let ((sql      (format nil "SELECT * FROM ~a" (table-source-name (source sqlite))))
        (pgtypes  (map 'vector #'column-type-name (columns sqlite))))
    (with-connection (*sqlite-db* (source-db sqlite))
      (let* ((db (conn-handle *sqlite-db*))
             (encoding (sqlite-encoding db)))
        (handler-case
            (loop
               with statement = (sqlite:prepare-statement db sql)
               with len = (loop :for name
                             :in (sqlite:statement-column-names statement)
                             :count name)
               while (sqlite:step-statement statement)
               for row = (let ((v (make-array len)))
                           (loop :for x :below len
                              :for raw := (sqlite:statement-column-value statement x)
                              :for ptype := (aref pgtypes x)
                              :for stype := (sqlite-ffi:sqlite3-column-type
                                             (sqlite::handle statement)
                                             x)
                              :for val := (parse-value raw stype ptype
                                                       :encoding encoding)
                              :do (setf (aref v x) val))
                           v)
               counting t into rows
               do (funcall process-row-fn row)
               finally
                 (sqlite:finalize-statement statement)
                 (return rows))
          (condition (e)
            (log-message :error "~a" e)
            (update-stats :data (target sqlite) :errs 1)))))))

(defmethod fetch-metadata (sqlite catalog
                           &key
                             materialize-views
                             only-tables
                             create-indexes
                             foreign-keys
                             including
                             excluding)
  "SQLite introspection to prepare the migration."
  (declare (ignore materialize-views only-tables foreign-keys))
  (let ((schema (add-schema catalog nil)))
    (with-stats-collection ("fetch meta data"
                            :use-result-as-rows t
                            :use-result-as-read t
                            :section :pre)
        (with-connection (conn (source-db sqlite))
          (let ((*sqlite-db* (conn-handle conn)))
            (list-all-columns schema
                              :db *sqlite-db*
                              :including including
                              :excluding excluding)

            (when create-indexes
              (list-all-indexes schema
                                :db *sqlite-db*
                                :including including
                                :excluding excluding)))

          ;; return how many objects we're going to deal with in total
          ;; for stats collection
          (+ (count-tables catalog) (count-indexes catalog))))
    catalog))


