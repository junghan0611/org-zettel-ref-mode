;;; org-zettel-ref-db.el --- Database operations for org-zettel-ref -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'org-roam nil t)  ; Safely attempt to load org-roam
(require 'denote nil t)  ; Safely attempt to load denote

;;;----------------------------------------------------------------------------
;;; Org-roam Database intergration
;;;----------------------------------------------------------------------------

(declare-function org-zettel-ref-refresh-index "org-zettel-ref-core")


(defun org-zettel-ref-update-roam-db (file)
  "Update Org-roam database for FILE.
This function will update or insert the node in org-roam database."
  (when (and (require 'org-roam nil t)
             (file-exists-p file))
    (let* ((node (org-roam-db-query
                  [:select [id title properties file hash]
                   :from nodes
                   :where (= file $s1)]
                  file))
           (current-hash (org-roam-db--file-hash file)))
      (if node
          ;; Update existing node
          (let ((node-id (gethash "id" (car node)))
                (old-hash (gethash "hash" (car node))))
            (unless (string= current-hash old-hash)
              (org-roam-db-clear-file file)
              (org-roam-db-update-file file)
              (message "Updated Org-roam node: %s" file)))
        ;; Insert new node
        (org-roam-db-update-file file)
        (message "Inserted new Org-roam node: %s" file)))))

(defun org-zettel-ref-update-org-roam-db (file)
  "Synchronize reference database for FILE.
When using org-roam mode, update the org-roam database with reference data.
Other database modes may be supported in the future."
  (cond
   ((eq org-zettel-ref-mode-type 'org-roam)
    (org-zettel-ref-update-roam-db file))
   ;; Add other database update methods here if needed
   (t (message "No database update method for current mode type"))))

(defun org-zettel-ref-check-roam-db ()
  "Check the status of the org-roam database."
  (interactive)
  (if (require 'org-roam nil t)
      (condition-case err
          (progn
            (message "Org-roam version: %s" (org-roam-version))
            (message "Org-roam directory: %s" org-roam-directory)
            (message "Org-roam database file: %s" org-roam-db-location)
            (if (file-exists-p org-roam-db-location)
                (message "Database file exists")
              (message "Database file does not exist"))
            (let ((node-count (caar (org-roam-db-query [:select (funcall count *) :from nodes]))))
              (message "Number of nodes in database: %d" node-count)))
        (error
         (message "Error checking org-roam database: %S" err)))
    (message "Org-roam is not available")))




;;;----------------------------------------------------------------------------
;;; Variables
;;;----------------------------------------------------------------------------

(defcustom org-zettel-ref-db-file (expand-file-name ".zettel-ref-db.el" user-emacs-directory)
  "The file path for storing the org-zettel-ref database."
  :type 'file
  :group 'org-zettel-ref)

(defconst org-zettel-ref-db-version "1.0"
  "Version of the org-zettel-ref database format.")

(defvar org-zettel-ref-mode-type nil
  "The current mode type for org-zettel-ref.
Can be 'org-roam, 'denote, or nil for standalone mode.")

(defvar org-zettel-ref-db nil
  "The global database instance for org-zettel-ref.")

;;;----------------------------------------------------------------------------
;;; Database Structures
;;;----------------------------------------------------------------------------

(cl-defstruct org-zettel-ref-db
  "Zettel reference database structure."
  (version "1.0")                     
  (timestamp (current-time))          
  (refs (make-hash-table :test 'equal))
  (overviews (make-hash-table :test 'equal))
  (map (make-hash-table :test 'equal))
  (ref-paths (make-hash-table :test 'equal))
  (overview-paths (make-hash-table :test 'equal))
  (modified nil)                      
  (dirty nil)
  (id-counter 0))




;; 2. Reference entry structure
(cl-defstruct (org-zettel-ref-ref-entry
               (:constructor org-zettel-ref-ref-entry-create)
               (:copier org-zettel-ref-ref-entry-copy))
  "Reference entry structure."
  (id nil :type string)                                  ; Reference ID
  (file-path nil :type string)                          ; File path
  (title nil :type string)                              ; Title
  (author nil :type string)                             ; Author
  (keywords nil :type list)                           ; Keywords list
  (created nil)                            ; Creation time
  (modified nil)                           ; Modified time
  (read-status 'unread :type symbol)              ; Reading status: unread, reading, done
  (rating 0 :type number))                        ; Rating: 0-5 stars

;; 3. Overview entry structure
(cl-defstruct (org-zettel-ref-overview-entry
               (:constructor org-zettel-ref-overview-entry-create)
               (:copier org-zettel-ref-overview-entry-copy))
  "Overview entry structure."
  (id nil :type string)                ; Overview ID
  (ref-id nil :type string)           ; Corresponding reference ID
  (file-path nil :type string)        ; File path
  (title nil :type string)            ; Title
  (created nil)                       ; Creation time
  (modified nil))                     ; Modified time

;;;----------------------------------------------------------------------------
;;; Database Initialization
;;;----------------------------------------------------------------------------

(defun org-zettel-ref-db-p (obj)
  "Return t if OBJ is a valid database instance."
  (and obj
       (recordp obj)  ; Check if it's a record (struct) type
       (eq (type-of obj) 'org-zettel-ref-db)  ; Check specific type
       (hash-table-p (org-zettel-ref-db-refs obj))
       (hash-table-p (org-zettel-ref-db-overviews obj))
       (hash-table-p (org-zettel-ref-db-map obj))
       (hash-table-p (org-zettel-ref-db-ref-paths obj))
       (hash-table-p (org-zettel-ref-db-overview-paths obj))))

(defun org-zettel-ref-init-db ()
  "Initialize a new database with proper structure."
  ;; Create a new database instance
  (let ((db (make-org-zettel-ref-db
             :version "1.0"
             :timestamp (current-time)
             :refs (make-hash-table :test 'equal)
             :overviews (make-hash-table :test 'equal)
             :map (make-hash-table :test 'equal)
             :ref-paths (make-hash-table :test 'equal)
             :overview-paths (make-hash-table :test 'equal)
             :modified (current-time)
             :dirty t)))
    
    ;; If the database file does not exist, save the newly created database
    (unless (file-exists-p org-zettel-ref-db-file)
      (org-zettel-ref-db-save db))
    
    db))

(defun org-zettel-ref-ensure-directory ()
  "Ensure the directory exists."
  (unless (file-exists-p org-zettel-ref-db-directory)
    (make-directory org-zettel-ref-db-directory)))

(defun org-zettel-ref-ensure-db ()
  "Ensure database is initialized and loaded.
Return the database instance."
  (unless org-zettel-ref-db
    ;; Ensure directory exists
    (let ((db-dir (file-name-directory org-zettel-ref-db-file)))
      (unless (file-exists-p db-dir)
        (make-directory db-dir t)))
    
    ;; Try to load existing database
    (condition-case err
        (if (file-exists-p org-zettel-ref-db-file)
            (progn
              (setq org-zettel-ref-db (org-zettel-ref-db-load org-zettel-ref-db-file))
              (unless org-zettel-ref-db
                (error "Failed to load database: loaded database is nil"))
              (message "Loaded database from %s" org-zettel-ref-db-file))
          ;; Create new database if none exists
          (progn
            (message "Creating new database at %s" org-zettel-ref-db-file)
            (setq org-zettel-ref-db (org-zettel-ref-db-create org-zettel-ref-db-file))
            (unless org-zettel-ref-db
              (error "Failed to create new database"))))
      (error
       (message "Error in database operation: %s" (error-message-string err))
       ;; Try one last time to create a fresh database
       (setq org-zettel-ref-db (org-zettel-ref-db-create org-zettel-ref-db-file))
       (unless org-zettel-ref-db
         (error "Failed to initialize database after error: %s" 
                (error-message-string err))))))
  
  ;; Final check to ensure we have a valid database
  (unless (org-zettel-ref-db-p org-zettel-ref-db)
    (error "Database validation failed"))
  
  org-zettel-ref-db)

(defun org-zettel-ref-db-create (file-path)
  "Create a new database and save it to FILE-PATH.
Return the new database instance."
  (let ((db (make-org-zettel-ref-db
             :version "1.0"
             :timestamp (current-time)
             :refs (make-hash-table :test 'equal)
             :overviews (make-hash-table :test 'equal)
             :map (make-hash-table :test 'equal)
             :ref-paths (make-hash-table :test 'equal)
             :overview-paths (make-hash-table :test 'equal)
             :modified (current-time)
             :dirty t)))
    ;; Save the newly created database
    (org-zettel-ref-db-save db file-path)
    db))

;;;----------------------------------------------------------------------------
;;; Database Creation Functions
;;;----------------------------------------------------------------------------

(defun org-zettel-ref-db-create-ref-entry (db file-path title author keywords)
  "Create a new reference entry.
DB is the database object, FILE-PATH is the file path, TITLE is the title,
AUTHOR is the author, KEYWORDS is the keywords list."
  (let* ((base-id (format-time-string "%Y%m%dT%H%M%S"))
         (id base-id)
         (counter 0)
         (now (current-time)))
    ;; Ensure the ID is unique
    (while (and (< counter 1000)
                (gethash id (org-zettel-ref-db-refs db)))
      (setq counter (1+ counter)
            id (format "%s-%03d" base-id counter)))
    ;; Print debug information
    (message "DEBUG: Creating ref entry - ID: %s, Title: %s" id title)
    (org-zettel-ref-ref-entry-create
     :id id
     :file-path file-path
     :title title
     :author author
     :keywords keywords
     :created now
     :modified now
     :read-status 'unread
     :rating 0)))

(defun org-zettel-ref-db-create-overview-entry (db ref-id file-path &optional title)
  "Create a new overview entry.
DB is the database object, REF-ID is the corresponding reference ID,
FILE-PATH is the file path, TITLE is the title."
  (let* ((id ref-id)  ; 使用 ref-id 作为 overview 的 id
         (timestamp (current-time)))
    (org-zettel-ref-overview-entry-create
     :id id
     :ref-id ref-id
     :file-path file-path
     :title (or title (file-name-base file-path))
     :created timestamp
     :modified timestamp)))

;;;----------------------------------------------------------------------------
;;; Database Entry Operations: Add
;;;----------------------------------------------------------------------------

(defun org-zettel-ref-db-add-ref-entry (db entry)
  "Add a reference entry to the database.
DB is the database object, ENTRY is the reference entry."
  (let ((id (org-zettel-ref-ref-entry-id entry))
        (file-path (org-zettel-ref-ref-entry-file-path entry)))
    ;; Check if there is already an entry with the same file path
    (when-let* ((existing-id (gethash file-path (org-zettel-ref-db-ref-paths db))))
      (remhash existing-id (org-zettel-ref-db-refs db)))
    ;; Add the new entry
    (puthash id entry (org-zettel-ref-db-refs db))
    (puthash file-path id (org-zettel-ref-db-ref-paths db))
    (setf (org-zettel-ref-db-modified db) (current-time)
          (org-zettel-ref-db-dirty db) t)
    ;; Print debug information
    (message "DEBUG: Added ref entry - ID: %s, Title: %s, Path: %s" 
             id 
             (org-zettel-ref-ref-entry-title entry)
             file-path)
    (message "DEBUG: Current refs count: %d" 
             (hash-table-count (org-zettel-ref-db-refs db)))
    id))

(defun org-zettel-ref-db-add-overview-entry (db entry)
  "Add an overview entry to the database.
DB is the database object, ENTRY is the overview entry."
  (let ((id (org-zettel-ref-overview-entry-id entry))
        (file-path (org-zettel-ref-overview-entry-file-path entry)))
    (puthash id entry (org-zettel-ref-db-overviews db))
    (puthash file-path id (org-zettel-ref-db-overview-paths db))
    (setf (org-zettel-ref-db-modified db) (current-time)
          (org-zettel-ref-db-dirty db) t)
    ;; Print debug information
    (message "DEBUG: Added overview entry - ID: %s, Title: %s" 
             id (org-zettel-ref-overview-entry-title entry))
    (message "DEBUG: Current overviews count: %d" 
             (hash-table-count (org-zettel-ref-db-overviews db)))
    id))

(defun org-zettel-ref-ref-entry-set-read-status (entry status)
  "Set the read status of ENTRY to STATUS.
STATUS should be one of: 'unread, 'reading, 'done."
  (setf (org-zettel-ref-ref-entry-read-status entry) status))

(defun org-zettel-ref-ref-entry-set-rating (entry rating)
  "Set the rating of ENTRY to RATING.
RATING should be a number between 0 and 5."
  (setf (org-zettel-ref-ref-entry-rating entry) rating))
  
;;;----------------------------------------------------------------------------
;;; Database Entry Operations: Ensure
;;;---------------------------------------------------------------------------- 

(defvar org-zettel-ref-id-counter 0
  "Counter for generating unique IDs within the same timestamp.")

(defun org-zettel-ref-generate-id (db)
  "Generate a unique ID for a reference entry using DB's counter."
  (let* ((timestamp (format-time-string "%Y%m%dT%H%M%S"))
         (counter (cl-incf (org-zettel-ref-db-id-counter db)))
         (id (format "%s-%03d" timestamp counter)))
    (message "DEBUG: Generated new ID: %s" id)
    id))


(defun org-zettel-ref-db-ensure-ref-entry (db file-path &optional title author keywords status rating)
  "Ensure a reference entry exists in DB for FILE-PATH.
Create a new entry if it doesn't exist.
Optional parameters:
- TITLE: entry title, defaults to file name without extension
- AUTHOR: entry author
- KEYWORDS: list of keywords
- STATUS: reading status ('unread, 'reading, 'done)
- RATING: numeric rating (0-5)
Return the reference entry object."
  (let* ((abs-path (expand-file-name file-path))
         (ref-id (org-zettel-ref-db-get-ref-id-by-path db abs-path)))
    (if ref-id
        ;; Return existing entry but update its fields
        (let ((entry (gethash ref-id (org-zettel-ref-db-refs db))))
          (when entry
            ;; Update fields if provided
            (when title
              (setf (org-zettel-ref-ref-entry-title entry) title))
            (when author
              (setf (org-zettel-ref-ref-entry-author entry) author))
            (when keywords
              (setf (org-zettel-ref-ref-entry-keywords entry) keywords))
            (when status
              (setf (org-zettel-ref-ref-entry-read-status entry) status))
            (when rating
              (setf (org-zettel-ref-ref-entry-rating entry) rating))
            ;; Update file path and modified time
            (setf (org-zettel-ref-ref-entry-file-path entry) abs-path
                  (org-zettel-ref-ref-entry-modified entry) (current-time))
            ;; Update path mapping
            (maphash (lambda (path id)
                      (when (equal id ref-id)
                        (remhash path (org-zettel-ref-db-ref-paths db))))
                    (org-zettel-ref-db-ref-paths db))
            (puthash abs-path ref-id (org-zettel-ref-db-ref-paths db))
            ;; Save database after update
            (org-zettel-ref-db-save db)
            ;; Return updated entry
            entry))
      ;; Create and return new entry
      (let* ((file-name (file-name-nondirectory abs-path))
             (parsed-info (org-zettel-ref-parse-filename file-name))
             (new-ref-id (org-zettel-ref-generate-id db))  
             (entry (org-zettel-ref-ref-entry-create
                    :id new-ref-id
                    :file-path abs-path
                    :title (or title 
                             (nth 1 parsed-info)
                             (file-name-base abs-path))
                    :author (or author 
                              (nth 0 parsed-info))
                    :keywords (or keywords 
                                (nth 2 parsed-info))
                    :created (current-time)
                    :modified (file-attribute-modification-time 
                             (file-attributes abs-path))
                    :read-status (or status 
                                   (nth 3 parsed-info)
                                   'unread)
                    :rating (or rating 
                              (nth 4 parsed-info)
                              0))))
        ;; Add to database
        (puthash new-ref-id entry (org-zettel-ref-db-refs db))
        (puthash abs-path new-ref-id (org-zettel-ref-db-ref-paths db))
        ;; Save database after creating new entry
        (org-zettel-ref-db-save db)
        entry))))

(defun org-zettel-ref-db-ensure-overview-entry (db ref-entry file-path &optional title)
  "Ensure there is an overview entry for the reference entry.
DB is the database object, REF-ENTRY is the reference entry,
FILE-PATH is the overview file path.
TITLE is the optional title. If not provided, the reference entry's title will be used.
Return the overview entry object."
  (let* ((ref-id (org-zettel-ref-ref-entry-id ref-entry))
         (existing-overview-id (org-zettel-ref-db-get-maps db ref-id)))
    
    (or ;; 1. Try to get the existing overview entry
        (when existing-overview-id
          (let ((overview (gethash existing-overview-id 
                                  (org-zettel-ref-db-overviews db))))
            (when (and overview
                      (file-exists-p (org-zettel-ref-overview-entry-file-path overview)))
              overview)))
        
        ;; 2. Try to get the overview entry by file path
        (when-let* ((path-overview-id (gethash file-path 
                                             (org-zettel-ref-db-overview-paths db))))
          (let ((overview (gethash path-overview-id 
                                  (org-zettel-ref-db-overviews db))))
            (when overview
              ;; Update the mapping relationship
              (org-zettel-ref-db-add-map db ref-id path-overview-id)
              overview)))
        
        ;; 3. Create a new overview entry
        (let* ((overview-title (or title 
                                  (org-zettel-ref-ref-entry-title ref-entry)))
               (new-entry (org-zettel-ref-db-create-overview-entry 
                          db ref-id file-path overview-title)))
          ;; Add to the database
          (org-zettel-ref-db-add-overview-entry db new-entry)
          ;; Establish the mapping relationship
          (org-zettel-ref-db-add-map db ref-id 
                                    (org-zettel-ref-overview-entry-id new-entry))
          new-entry))))

;;;----------------------------------------------------------------------------
;;; Database Query Functions
;;;----------------------------------------------------------------------------

(defun org-zettel-ref-db-get-ref-by-path (db file-path)
  "DB is the database object, FILE-PATH is the file path.
Return the corresponding reference entry, or nil if it doesn't exist."
  (when-let* ((ref-id (org-zettel-ref-db-get-ref-id-by-path db file-path)))
    (org-zettel-ref-db-get-ref-entry db ref-id)))

(defun org-zettel-ref-db-get-ref-by-title (db title)
  "DB is the database object, TITLE is the title.
Return the corresponding reference entry, or nil if it doesn't exist."
  (let (result)
    (maphash (lambda (id entry)
               (when (and (org-zettel-ref-ref-entry-p entry)
                         (string-match-p (regexp-quote title) 
                                       (org-zettel-ref-ref-entry-title entry)))
                 (push entry result)))
             (org-zettel-ref-db-refs db))
    (nreverse result)))

(defun org-zettel-ref-db-get-overview-by-ref-id (db ref-id)
  "Get the overview entry by reference ID.
DB is the database object, REF-ID is the reference ID.
Return the overview entry object."
  (when-let* ((overview-id (org-zettel-ref-db-get-maps db ref-id)))
    (let ((entry (gethash overview-id (org-zettel-ref-db-overviews db))))
      ;; ensure return is a single entry instead of a list
      (if (org-zettel-ref-overview-entry-p entry)
          entry
        (car entry)))))


(defun org-zettel-ref-db-get-ref-id-by-path (db file)
  "Get reference ID by file path.
DB is the database object, FILE is the file path.
Return the reference ID or nil if not found."
  (let ((file-path (expand-file-name file)))
    (gethash file-path (org-zettel-ref-db-ref-paths db))))

(defun org-zettel-ref-db-get-ref-id-by-title (db title)
  "Get the reference ID by title.
DB is the database object, TITLE is the title.
Return the reference ID."
  (let ((found-id nil))
    (maphash
     (lambda (id entry)
       (when (and (null found-id)
                  (equal title
                         (org-zettel-ref-ref-entry-title entry)))
         (setq found-id id)))
     (org-zettel-ref-db-refs db))
    found-id))

(defun org-zettel-ref-db-get-ref-entry (db ref-id)
  "Get the reference entry by reference ID.
DB is the database object, REF-ID is the reference ID.
Return the reference entry object."
  (gethash ref-id (org-zettel-ref-db-refs db)))

(defun org-zettel-ref-db-get-maps (db ref-id)
  "Get the overview ID by reference ID.
DB is the database object, REF-ID is the reference ID.
Return the overview ID."
  (unless db
    (error "Database is nil"))
  (gethash ref-id (org-zettel-ref-db-map db)))

(defun org-zettel-ref-db-add-map (db ref-id overview-id)
  "Add the mapping of reference ID and overview ID.
DB is the database object, REF-ID is the reference ID, OVERVIEW-ID is the overview ID.
Return the mapping ID."
  (unless db
    (error "Database is nil"))
  (puthash ref-id overview-id (org-zettel-ref-db-map db)))

;;;----------------------------------------------------------------------------
;;; Database Update Functions
;;;----------------------------------------------------------------------------

(defun org-zettel-ref-db-update-ref-entry (db entry)
  "Update the reference entry.
DB is the database object, ENTRY is the reference entry.
Return the updated reference entry object."
  (let ((id (org-zettel-ref-ref-entry-id entry)))
    (setf (org-zettel-ref-ref-entry-modified entry) (current-time))
    (puthash id entry (org-zettel-ref-db-refs db))
    (setf (org-zettel-ref-db-modified db) (current-time)
          (org-zettel-ref-db-dirty db) t)
    entry))

(defun org-zettel-ref-db-update-ref-path (db old-path new-path)
  "Update the file path of the reference entry, keeping the ref-id unchanged.
DB is the database object, OLD-PATH is the old file path, NEW-PATH is the new file path.
Return the updated reference entry object."
  (when-let* ((ref-id (org-zettel-ref-db-get-ref-id-by-path db old-path)))
    (remhash old-path (org-zettel-ref-db-ref-paths db))
    (puthash new-path ref-id (org-zettel-ref-db-ref-paths db))
    ref-id))

;;;----------------------------------------------------------------------------
;;; Database Save & Load  
;;;----------------------------------------------------------------------------

(cl-defun org-zettel-ref-db-save (db &optional file-path)
  "Save database DB to FILE-PATH or default location.
Return the saved database object."
  (let ((print-length nil)
        (print-level nil)
        (file (or file-path org-zettel-ref-db-file)))
    (with-temp-file file
      (let ((print-circle t))  ; Handle circular references
        (prin1 (list :version org-zettel-ref-db-version
                     :timestamp (current-time)
                     :refs (org-zettel-ref-db-refs db)
                     :overviews (org-zettel-ref-db-overviews db)
                     :map (org-zettel-ref-db-map db)
                     :ref-paths (org-zettel-ref-db-ref-paths db)
                     :overview-paths (org-zettel-ref-db-overview-paths db)
                     :id-counter (org-zettel-ref-db-id-counter db))
               (current-buffer))))
    (setf (org-zettel-ref-db-modified db) (current-time)
          (org-zettel-ref-db-dirty db) nil)
    (message "Database saved to %s" file)
    db))

(defun org-zettel-ref-db-migrate-entries (db)
  "Migrate old database entries to the new format.
DB is the database object."
  (let ((modified nil))
    (maphash
     (lambda (id entry)
       (when (org-zettel-ref-ref-entry-p entry)
         ;; Check if entry needs migration
         (unless (and (slot-exists-p entry 'read-status)
                     (slot-exists-p entry 'rating))
           ;; Create a new entry with all fields
           (let* ((new-entry (org-zettel-ref-ref-entry-create
                             :id (org-zettel-ref-ref-entry-id entry)
                             :file-path (org-zettel-ref-ref-entry-file-path entry)
                             :title (org-zettel-ref-ref-entry-title entry)
                             :author (org-zettel-ref-ref-entry-author entry)
                             :keywords (org-zettel-ref-ref-entry-keywords entry)
                             :created (org-zettel-ref-ref-entry-created entry)
                             :modified (org-zettel-ref-ref-entry-modified entry)
                             :read-status 'unread
                             :rating 0)))
             ;; Replace old entry with new one
             (puthash id new-entry (org-zettel-ref-db-refs db))
             (setq modified t)))))
     (org-zettel-ref-db-refs db))
    ;; Save if modified
    (when modified
      (setf (org-zettel-ref-db-modified db) (current-time)
            (org-zettel-ref-db-dirty db) t)
      (org-zettel-ref-db-save db))
    modified))

(defun org-zettel-ref-db-load (file)
  "Load the database from FILE.
Return the database object or nil if loading fails."
  (when (file-exists-p file)
    (condition-case err
        (with-temp-buffer
          (insert-file-contents file)
          (let* ((data (read (current-buffer)))
                 (version (plist-get data :version))
                 (timestamp (plist-get data :timestamp))
                 (old-refs (plist-get data :refs))
                 (old-overviews (plist-get data :overviews))
                 (old-map (plist-get data :map))
                 (old-ref-paths (plist-get data :ref-paths))
                 (old-overview-paths (plist-get data :overview-paths))
                 (id-counter (plist-get data :id-counter))
                 ;; Create new hash tables with proper test function
                 (refs (make-hash-table :test 'equal))
                 (overviews (make-hash-table :test 'equal))
                 (map (make-hash-table :test 'equal))
                 (ref-paths (make-hash-table :test 'equal))
                 (overview-paths (make-hash-table :test 'equal)))
            
            ;; Copy data from old hash tables to new ones
            (when old-refs
              (maphash (lambda (k v) (puthash k v refs)) old-refs))
            (when old-overviews
              (maphash (lambda (k v) (puthash k v overviews)) old-overviews))
            (when old-map
              (maphash (lambda (k v) (puthash k v map)) old-map))
            (when old-ref-paths
              (maphash (lambda (k v) (puthash k v ref-paths)) old-ref-paths))
            (when old-overview-paths
              (maphash (lambda (k v) (puthash k v overview-paths)) old-overview-paths))
            
            (let ((db (make-org-zettel-ref-db
                      :version version
                      :timestamp timestamp
                      :refs refs
                      :overviews overviews
                      :map map
                      :ref-paths ref-paths
                      :overview-paths overview-paths
                      :modified timestamp
                      :id-counter (or id-counter 0)
                      :dirty nil)))
              
              (message "DEBUG: Loaded database from %s" file)
              (message "DEBUG: Version: %s, ID Counter: %d"
                      version (org-zettel-ref-db-id-counter db))
              (message "DEBUG: Refs: %d, Overviews: %d, Maps: %d"
                      (hash-table-count refs)
                      (hash-table-count overviews)
                      (hash-table-count map))
              db)))
      (error
       (message "Error loading database from %s: %s" 
                file (error-message-string err))
       nil))))
       
;;;----------------------------------------------------------------------------
;;; Debug Functions
;;;----------------------------------------------------------------------------

(defun org-zettel-ref-db-debug-info (db)
  "Display debug information for the database."
  (when org-zettel-ref-debug
    (org-zettel-ref-debug-message-category 'db "\n=== Database Debug Information ===")
    (org-zettel-ref-debug-message-category 'db "Reference Table Contents:")
    (maphash (lambda (id entry)
               (org-zettel-ref-debug-message-category 
                'db "  ID: %s, Title: %s"
                id (org-zettel-ref-ref-entry-title entry)))
             (org-zettel-ref-db-refs db))))

;;;----------------------------------------------------------------------------
;;; Advanced Database Operations
;;;----------------------------------------------------------------------------

(defun org-zettel-ref-db-get-ref-by-keyword (db keyword)
  "DB is the database object, KEYWORD is the keyword.
Return the reference entry object."
  (let (result)
    (maphash (lambda (_id entry)
               (when (member keyword (org-zettel-ref-ref-entry-keywords entry))
                 (push entry result)))
             (org-zettel-ref-db-refs db))
    (nreverse result)))

(defun org-zettel-ref-db-get-ref-by-author (db author)
  "Get the reference entry by author.
DB is the database object, AUTHOR is the author.
Return the reference entry object."
  (let (result)
    (maphash (lambda (_id entry)
               (when (and (org-zettel-ref-ref-entry-author entry)
                         (string-match-p (regexp-quote author)
                                       (org-zettel-ref-ref-entry-author entry)))
                 (push entry result)))
             (org-zettel-ref-db-refs db))
    (nreverse result)))

(defun org-zettel-ref-db-cleanup (db)
  "Cleanup invalid entries in the database.
DB is the database object.
Return the updated reference entry object."
  (let ((modified nil))
    ;; Cleanup invalid reference files
    (maphash (lambda (file-path ref-id)
               (unless (file-exists-p file-path)
                 (remhash file-path (org-zettel-ref-db-ref-paths db))
                 (when-let* ((entry (gethash ref-id (org-zettel-ref-db-refs db))))
                   (remhash ref-id (org-zettel-ref-db-refs db)))
                 (setq modified t)))
             (org-zettel-ref-db-ref-paths db))
    
    ;; Cleanup invalid overview files
    (maphash (lambda (file-path overview-id)
               (unless (file-exists-p file-path)
                 (remhash file-path (org-zettel-ref-db-overview-paths db))
                 (when-let* ((entry (gethash overview-id (org-zettel-ref-db-overviews db))))
                   (remhash overview-id (org-zettel-ref-db-overviews db)))
                 (setq modified t)))
             (org-zettel-ref-db-overview-paths db))
    
    ;; Set modified flag
    (when modified
      (setf (org-zettel-ref-db-modified db) (current-time)
            (org-zettel-ref-db-dirty db) t))
    modified))

;;;----------------------------------------------------------------------------
;;; Advanced Search and Filter Functions
;;;----------------------------------------------------------------------------

(defun org-zettel-ref-db-analyze-connections (db)
  "Analyze the connections in the database.
DB is the database object.
Return the analysis result."
  (let ((keyword-connections (make-hash-table :test 'equal))
        (author-connections (make-hash-table :test 'equal)))
    
    ;; Analyze keyword co-occurrence
    (maphash
     (lambda (_id entry)
       (let ((keywords (org-zettel-ref-ref-entry-keywords entry)))
         (dolist (kw1 keywords)
           (dolist (kw2 keywords)
             (unless (equal kw1 kw2)
               ;; Use string comparison instead of numeric comparison
               (let* ((kw1-str (if (stringp kw1) kw1 (format "%s" kw1)))
                     (kw2-str (if (stringp kw2) kw2 (format "%s" kw2)))
                     (pair (if (string< kw1-str kw2-str)
                             (cons kw1-str kw2-str)
                           (cons kw2-str kw1-str))))
                 (puthash pair
                         (1+ (gethash pair keyword-connections 0))
                         keyword-connections)))))))
     (org-zettel-ref-db-refs db))
    
    ;; Analyze author collaboration
    (let ((author-keywords (make-hash-table :test 'equal)))
      (maphash
       (lambda (_id entry)
         (let ((author (org-zettel-ref-ref-entry-author entry))
               (keywords (org-zettel-ref-ref-entry-keywords entry)))
           (when author
             (puthash author
                     (append keywords
                            (gethash author author-keywords))
                     author-keywords))))
       (org-zettel-ref-db-refs db))
      
      ;; Find keyword overlap
      (maphash
       (lambda (author1 kws1)
         (maphash
          (lambda (author2 kws2)
            (unless (equal author1 author2)
              (let* ((common (cl-intersection kws1 kws2 :test 'equal))
                     (pair (if (string< author1 author2)
                             (cons author1 author2)
                           (cons author2 author1))))
                (when common
                  (puthash pair
                          (length common)
                          author-connections)))))
          author-keywords))
       author-keywords))
    
    ;; Return analysis result
    (list :keyword-connections
          (let (pairs)
            (maphash (lambda (k v) (push (cons k v) pairs))
                    keyword-connections)
            (sort pairs (lambda (a b) (> (cdr a) (cdr b)))))
          :author-connections
          (let (pairs)
            (maphash (lambda (k v) (push (cons k v) pairs))
                    author-connections)
            (sort pairs (lambda (a b) (> (cdr a) (cdr b))))))))

;; Generate Dot Graph

(defun org-zettel-ref-db-generate-dot (db output-file)
  "Generate a GraphViz DOT formatted relationship graph.
DB is the database object, OUTPUT-FILE is the output file path.
Return the updated reference entry object."
  (with-temp-file output-file
    (insert "digraph ZettelRef {\n")
    (insert "  rankdir=LR;\n")
    (insert "  node [shape=box, style=rounded];\n")
    (insert "  // Authors node\n")
    (insert "  subgraph cluster_authors {\n")
    (insert "    label=\"Authors\";\n")
    (insert "    style=filled;\n")
    (insert "    color=lightgrey;\n")
    
    ;; Add authors node
    (let ((authors (make-hash-table :test 'equal)))
      (maphash
       (lambda (_id entry)
         (let ((author (org-zettel-ref-ref-entry-author entry)))
           (when author
             (puthash author t authors))))
      (maphash
       (lambda (author _)
         (insert (format "    \"%s\" [shape=ellipse];\n" author)))
       authors))
    (insert "  }\n\n")
    
    ;; Add keywords node
    (insert "  subgraph cluster_keywords {\n")
    (insert "    label=\"Keywords\";\n")
    (insert "    style=filled;\n")
    (insert "    color=lightblue;\n")
    (let ((keywords (make-hash-table :test 'equal)))
      (maphash
       (lambda (_id entry)
         (dolist (kw (org-zettel-ref-ref-entry-keywords entry))
           (puthash kw t keywords)))
       (org-zettel-ref-db-refs db))
      (maphash
       (lambda (keyword _)
         (insert (format "    \"%s\" [shape=diamond];\n" keyword)))
       keywords))
    (insert "  }\n\n")
    
    ;; Add author-keyword relationships
    (maphash
     (lambda (_id entry)
       (let ((author (org-zettel-ref-ref-entry-author entry)))
         (when author
           (dolist (kw (org-zettel-ref-ref-entry-keywords entry))
             (insert (format "  \"%s\" -> \"%s\" [color=blue];\n"
                           author kw))))))
     (org-zettel-ref-db-refs db))
    
    (insert "}\n"))))

;;;----------------------------------------------------------------------------
;;; Database Search and Filter Functions
;;;----------------------------------------------------------------------------

(defun org-zettel-ref-db-search (db &rest criteria)
  "Search for references in the database that match the given criteria.
DB is the database object, CRITERIA is the search criteria.
Return the search results."
  (let ((title (plist-get criteria :title))
        results)
    (message "DEBUG: Starting search with title pattern: %s" title)
    (message "DEBUG: Total refs in database: %d" 
             (hash-table-count (org-zettel-ref-db-refs db)))
    (maphash
     (lambda (id entry)
       (message "DEBUG: Checking entry - ID: %s, Title: %s" 
                id (org-zettel-ref-ref-entry-title entry))
       (when (or (null title)
                 (string-match-p title (org-zettel-ref-ref-entry-title entry)))
         (push entry results)))
     (org-zettel-ref-db-refs db))))


(defun org-zettel-ref-extract-org-property (file property)
  "Extract the value of a property from an org file.
FILE is the file path, PROPERTY is the property name.
Return the property value."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((case-fold-search t))
      (when (re-search-forward (format "^#\\+%s:[ \t]*\\(.*\\)$" property) nil t)
        (string-trim (match-string 1))))))


;; Core extraction functions
(defun org-zettel-ref-core-extract-ref (file)
  "Extract reference information from a file.
FILE is the file path.
Return the reference entry object."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (let ((title (or (org-zettel-ref-core-extract-property "TITLE") "Untitled"))
            (author (org-zettel-ref-core-extract-property "AUTHOR"))
            (keywords (org-zettel-ref-core-extract-keywords)))
        (org-zettel-ref-db-create-ref-entry
         file title author keywords)))))

(defun org-zettel-ref-core-extract-overview (file ref)
  "Extract overview information from a file.
FILE is the file path, REF is the reference entry object.
Return the overview entry object."
  (when (and (file-exists-p file)
             ref)
    (with-temp-buffer
      (insert-file-contents file)
      (let ((title (or (org-zettel-ref-core-extract-property "TITLE") "Untitled")))
        (org-zettel-ref-db-create-overview-entry
         (org-zettel-ref-ref-entry-id ref)
         file
         title)))))

(defun org-zettel-ref-core-extract-property (property)
  "Extract the value of a property from the current buffer.
PROPERTY is the property name.
Return the property value."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward (format "^#\\+%s:[ \t]*\\(.*\\)" property) nil t)
      (string-trim (match-string 1)))))

(defun org-zettel-ref-core-extract-keywords ()
  "Extract keywords from the current buffer.
Return the keywords list."
  (when-let* ((keywords-str (org-zettel-ref-core-extract-property "KEYWORDS")))
    (mapcar #'string-trim
            (split-string keywords-str ","))))


;;;----------------------------------------------------------------------------
;;; Database Statistics and Reports
;;;----------------------------------------------------------------------------

(defun org-zettel-ref-db-statistics (db)
  "Generate database statistics.
DB is the database object.
Return the statistics result."
  (let ((ref-count 0)
        (overview-count 0)
        (author-stats (make-hash-table :test 'equal))
        (keyword-stats (make-hash-table :test 'equal)))
    

    (message "DEBUG: Total refs in database: %d" 
             (hash-table-count (org-zettel-ref-db-refs db)))
    
    ;; Statistics reference
    (maphash
     (lambda (id entry)
       (cl-incf ref-count)
       (message "DEBUG: Processing ref - ID: %s, Title: %s" 
                id (org-zettel-ref-ref-entry-title entry))
       ;; Author statistics
       (when-let* ((author (org-zettel-ref-ref-entry-author entry)))
         (puthash author 
                 (1+ (gethash author author-stats 0))
                 author-stats))
       ;; Keyword statistics
       (dolist (kw (org-zettel-ref-ref-entry-keywords entry))
         (puthash kw 
                 (1+ (gethash kw keyword-stats 0))
                 keyword-stats)))
     (org-zettel-ref-db-refs db))
    
    (message "DEBUG: Statistics calculation completed")
    (message "DEBUG: Final ref count: %d" ref-count)
    
    (list :total-refs ref-count
          :total-overviews (hash-table-count (org-zettel-ref-db-overviews db))
          :authors (let (pairs)
                    (maphash (lambda (k v) (push (cons k v) pairs))
                            author-stats)
                    (sort pairs (lambda (a b) (> (cdr a) (cdr b)))))
          :keywords (let (pairs)
                     (maphash (lambda (k v) (push (cons k v) pairs))
                             keyword-stats)
                     (sort pairs (lambda (a b) (> (cdr a) (cdr b))))))))

(defun org-zettel-ref-db-print-report (db)
  "Print database report.
DB is the database object.
Return the statistics result."
  (let ((stats (org-zettel-ref-db-statistics db)))
    (message "\n=== Database Statistics Report ===")
    (message "Total references: %d" (plist-get stats :total-refs))
    (message "Total overviews: %d" (plist-get stats :total-overviews))
    
    (message "\nAuthor statistics:")
      (dolist (author (plist-get stats :authors))
      (message "  - %s: %d times" (car author) (cdr author)))
      
    (message "\nKeyword statistics:")
      (dolist (keyword (plist-get stats :keywords))
      (message "  - %s: %d times" (car keyword) (cdr keyword)))
      
    (message "\nRecent modifications:")
      (let (recent-items)
        (maphash (lambda (_id entry)
                   (push (cons (org-zettel-ref-ref-entry-title entry)
                             (org-zettel-ref-ref-entry-modified entry))
                         recent-items))
               (org-zettel-ref-db-refs db))
        ;; Sort by modification time
        (setq recent-items 
              (sort recent-items 
                    (lambda (a b) 
                      (time-less-p (cdr b) (cdr a)))))
      ;; Display recent 5 items
      (dolist (item (cl-subseq recent-items 0 (min 5 (length recent-items))))
        (message "  - %s: %s" 
                         (car item)
                (format-time-string "%Y-%m-%d %H:%M:%S" (cdr item)))))))



(provide 'org-zettel-ref-db)
;;; org-zettel-ref-db.el ends here

;; Setter functions for ref-entry fields

