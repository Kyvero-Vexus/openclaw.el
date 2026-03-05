;;; test-helper.el --- Test helpers for openclaw.el tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides mock WebSocket infrastructure and assertion helpers for
;; testing openclaw.el end-to-end without a live gateway.

;;; Code:

(require 'cl-lib)

;; Track test results
(defvar oc-test--results nil "List of (name passed-p message).")
(defvar oc-test--current-test nil "Name of currently running test.")

(defmacro oc-test-deftest (name docstring &rest body)
  "Define a test NAME with DOCSTRING and BODY.
BODY should call `oc-test-assert' for checks."
  (declare (indent 2))
  `(defun ,(intern (format "oc-test--%s" name)) ()
     ,docstring
     (setq oc-test--current-test ,(symbol-name name))
     (condition-case err
         (progn ,@body)
       (error
        (push (list ,(symbol-name name) nil (format "ERROR: %s" err))
              oc-test--results)))))

(defun oc-test-assert (condition message)
  "Assert CONDITION is non-nil, recording MESSAGE."
  (push (list oc-test--current-test condition message) oc-test--results)
  (unless condition
    (message "  FAIL: %s — %s" oc-test--current-test message)))

(defun oc-test-assert-equal (expected actual message)
  "Assert EXPECTED equals ACTUAL."
  (oc-test-assert (equal expected actual)
                  (if (equal expected actual)
                      message
                    (format "%s (expected %S, got %S)" message expected actual))))

(defun oc-test-assert-match (regexp string message)
  "Assert REGEXP matches STRING."
  (oc-test-assert (and (stringp string) (string-match regexp string))
                  (if (and (stringp string) (string-match regexp string))
                      message
                    (format "%s (regexp %S did not match %S)" message regexp string))))

(defun oc-test-assert-nonnil (value message)
  "Assert VALUE is non-nil."
  (oc-test-assert value message))

(defun oc-test-assert-nil (value message)
  "Assert VALUE is nil."
  (oc-test-assert (null value)
                  (if (null value) message
                    (format "%s (expected nil, got %S)" message value))))

;;; Mock WebSocket

(defvar oc-mock--sent-frames nil "List of JSON strings sent via mock WS.")
(defvar oc-mock--ws-open t "Whether mock WS reports as open.")
(defvar oc-mock--on-message-fn nil "Stored on-message callback.")
(defvar oc-mock--on-close-fn nil "Stored on-close callback.")
(defvar oc-mock--on-open-fn nil "Stored on-open callback.")

(defun oc-mock--reset ()
  "Reset all mock state."
  (setq oc-mock--sent-frames nil
        oc-mock--ws-open t
        oc-mock--on-message-fn nil
        oc-mock--on-close-fn nil
        oc-mock--on-open-fn nil
        openclaw--websocket nil
        openclaw--handshake-complete nil
        openclaw--connect-nonce nil
        openclaw--request-id 0
        openclaw--sessions (make-hash-table :test 'equal)
        openclaw--pending-requests (make-hash-table :test 'equal)))

(cl-defstruct oc-mock-ws
  "Mock websocket object."
  (open t))

(defun oc-mock--install ()
  "Install mock websocket layer.
Call this before tests that need to simulate gateway communication."
  (oc-mock--reset)

  ;; Mock websocket-open
  (advice-add 'websocket-open :override
              (lambda (url &rest args)
                (let ((ws (make-oc-mock-ws :open t)))
                  (setq oc-mock--on-message-fn (plist-get args :on-message)
                        oc-mock--on-close-fn (plist-get args :on-close)
                        oc-mock--on-open-fn (plist-get args :on-open))
                  ;; Trigger on-open
                  (when oc-mock--on-open-fn
                    (funcall oc-mock--on-open-fn ws))
                  ws))
              '((name . oc-mock-websocket-open)))

  ;; Mock websocket-send-text
  (advice-add 'websocket-send-text :override
              (lambda (_ws text)
                (push text oc-mock--sent-frames))
              '((name . oc-mock-websocket-send)))

  ;; Mock websocket-close
  (advice-add 'websocket-close :override
              (lambda (_ws)
                (setq oc-mock--ws-open nil))
              '((name . oc-mock-websocket-close)))

  ;; Mock websocket-openp
  (advice-add 'websocket-openp :override
              (lambda (_ws) oc-mock--ws-open)
              '((name . oc-mock-websocket-openp))))

(defun oc-mock--uninstall ()
  "Remove mock websocket layer."
  (advice-remove 'websocket-open 'oc-mock-websocket-open)
  (advice-remove 'websocket-send-text 'oc-mock-websocket-send)
  (advice-remove 'websocket-close 'oc-mock-websocket-close)
  (advice-remove 'websocket-openp 'oc-mock-websocket-openp))

(defun oc-mock--simulate-message (json-string)
  "Simulate receiving JSON-STRING from gateway."
  (when oc-mock--on-message-fn
    (let ((frame (make-websocket-frame :opcode 'text
                                       :payload json-string
                                       :length (length json-string)
                                       :completep t)))
      (funcall oc-mock--on-message-fn openclaw--websocket frame))))

(defun oc-mock--last-sent-parsed ()
  "Parse the most recently sent frame as JSON."
  (when oc-mock--sent-frames
    (json-read-from-string (car oc-mock--sent-frames))))

(defun oc-mock--sent-methods ()
  "Return list of methods from sent frames."
  (mapcar (lambda (f)
            (alist-get 'method (json-read-from-string f)))
          oc-mock--sent-frames))

(defun oc-mock--complete-handshake ()
  "Simulate a full gateway handshake sequence."
  ;; 1. Gateway sends challenge
  (oc-mock--simulate-message
   (json-encode `((type . "event")
                  (event . "connect.challenge")
                  (payload . ((nonce . "test-nonce-123")
                              (ts . 1737264000000))))))
  ;; 2. Client should have sent connect request - find its ID and respond
  (let* ((connect-frame (oc-mock--last-sent-parsed))
         (req-id (alist-get 'id connect-frame)))
    (when req-id
      (oc-mock--simulate-message
       (json-encode `((type . "res")
                      (id . ,req-id)
                      (ok . t)
                      (payload . ((type . "hello-ok")
                                  (protocol . 3)
                                  (policy . ((tickIntervalMs . 15000)))))))))))

(defun oc-mock--respond-to-last (payload)
  "Respond to the last sent request with PAYLOAD."
  (let* ((last-frame (oc-mock--last-sent-parsed))
         (req-id (alist-get 'id last-frame)))
    (when req-id
      (oc-mock--simulate-message
       (json-encode `((type . "res")
                      (id . ,req-id)
                      (ok . t)
                      (payload . ,payload)))))))

(provide 'test-helper)

;;; test-helper.el ends here
