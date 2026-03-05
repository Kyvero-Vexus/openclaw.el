;;; openclaw.el --- Emacs interface to OpenClaw -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Kyvero Vexus Corporation

;; Author: Kyvero Vexus <contact@kyverovexus.org>
;; URL: https://github.com/Kyvero-Vexus/openclaw.el
;; Keywords: comm tools ai
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (websocket "1.15"))

;; This file is part of openclaw.el.

;; openclaw.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; openclaw.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public License
;; along with openclaw.el.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides an Emacs interface to OpenClaw, allowing you to
;; interact with OpenClaw sessions directly from Emacs buffers.
;;
;; Each OpenClaw session gets its own buffer, and you can chat with the
;; assistant, send commands, and manage sessions.
;;
;; Quick start:
;;   M-x openclaw-connect RET
;;   M-x openclaw-chat RET
;;
;; Keybindings (when in openclaw-chat-mode):
;;   C-c C-c   - Send message
;;   C-c C-l   - List sessions
;;   C-c C-s   - Switch session
;;   C-c C-q   - Close connection
;;
;; Leader key mode (with C-c as leader):
;;   C-c c     - Connect to gateway
;;   C-c C     - Close connection
;;   C-c l     - List sessions
;;   C-c s     - Switch to session
;;   C-c n     - New chat
;;   C-c m     - Send message
;;   C-c h     - Show history
;;   C-c ?     - Show help

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'websocket)
(require 'button)


;;; Customization

(defgroup openclaw nil
  "Emacs interface to OpenClaw."
  :group 'comm
  :prefix "openclaw-")

(defcustom openclaw-gateway-url "ws://127.0.0.1:18789"
  "URL of the OpenClaw gateway."
  :type 'string
  :group 'openclaw)

(defcustom openclaw-gateway-token nil
  "Authentication token for the OpenClaw gateway.
If nil, will prompt for token or use password authentication."
  :type '(choice (const nil) string)
  :group 'openclaw)

(defcustom openclaw-gateway-password nil
  "Password for the OpenClaw gateway.
Used if token is not set."
  :type '(choice (const nil) string)
  :group 'openclaw)

(defcustom openclaw-leader-key "C-c"
  "Leader key prefix for openclaw commands."
  :type 'string
  :group 'openclaw)

(defcustom openclaw-session-buffer-name "*openclaw:%s*"
  "Format string for session buffer names."
  :type 'string
  :group 'openclaw)


;;; Variables

(defvar openclaw--websocket nil
  "Current websocket connection to the gateway.")

(defvar openclaw--request-id 0
  "Current request ID counter for JSON-RPC.")

(defvar openclaw--pending-requests (make-hash-table :test 'equal)
  "Hash table of pending request IDs to callbacks.")

(defvar openclaw--sessions (make-hash-table :test 'equal)
  "Hash table of session-key to session info.")

(defvar-local openclaw--current-session nil
  "Currently active session key (buffer-local).")

(defvar-local openclaw--session-label nil
  "Display label for current session (buffer-local).")

(defvar-local openclaw--message-history nil
  "List of recent messages for display (buffer-local).")

(defvar openclaw-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Direct commands
    (define-key map (kbd "C-c C-c") #'openclaw-send-message)
    (define-key map (kbd "C-c C-l") #'openclaw-list-sessions)
    (define-key map (kbd "C-c C-s") #'openclaw-switch-session)
    (define-key map (kbd "C-c C-n") #'openclaw-new-chat)
    (define-key map (kbd "C-c C-q") #'openclaw-close-connection)
    (define-key map (kbd "C-c C-h") #'openclaw-show-history)
    (define-key map (kbd "C-c ?") #'openclaw-help)
    
    ;; Leader-style bindings (with C-c as leader)
    ;; These are accessed via C-c c, C-c C, C-c l, etc.
    (define-key map (kbd "c") #'openclaw-connect)
    (define-key map (kbd "C") #'openclaw-close-connection)
    (define-key map (kbd "l") #'openclaw-list-sessions)
    (define-key map (kbd "s") #'openclaw-switch-session)
    (define-key map (kbd "n") #'openclaw-new-chat)
    (define-key map (kbd "m") #'openclaw-send-message)
    (define-key map (kbd "h") #'openclaw-show-history)
    (define-key map (kbd "?") #'openclaw-help)
    map)
  "Keymap for `openclaw-mode'.")

(defvar openclaw-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'openclaw-send-message)
    (define-key map (kbd "C-c C-c") #'openclaw-send-message)
    (define-key map (kbd "C-c C-l") #'openclaw-list-sessions)
    (define-key map (kbd "C-c C-s") #'openclaw-switch-session)
    (define-key map (kbd "C-c C-q") #'openclaw-close-connection)
    map)
  "Keymap for `openclaw-chat-mode'.")


;;; Major Mode

(define-derived-mode openclaw-mode fundamental-mode "OpenClaw"
  "Major mode for OpenClaw interaction.
This mode provides access to OpenClaw gateway functionality.
\\{openclaw-mode-map}"
  :group 'openclaw
  (buffer-disable-undo)
  (setq buffer-read-only t))

(define-derived-mode openclaw-chat-mode fundamental-mode "OpenClaw-Chat"
  "Major mode for chatting with OpenClaw sessions.
Each buffer represents a single session with the assistant.
\\{openclaw-chat-mode-map}"
  :group 'openclaw
  (buffer-disable-undo)
  (setq-local openclaw--current-session nil)
  (setq-local openclaw--session-label nil))

(defvar openclaw--connect-nonce nil
  "Nonce from gateway connect challenge.")

(defvar openclaw--handshake-complete nil
  "Non-nil when gateway handshake is complete.")

(defun openclaw--uuid ()
  "Generate a random UUID string."
  (format "%04x%04x-%04x-%04x-%04x-%04x%04x%04x"
          (random 65535) (random 65535)
          (random 65535)
          (logior 8192 (random 4096))  ; version 4
          (logior 49152 (random 16384)) ; variant
          (random 65535) (random 65535) (random 65535)))


;;; WebSocket Communication

(defun openclaw--next-request-id ()
  "Generate the next request ID (UUID)."
  (openclaw--uuid))

(defun openclaw--make-request (method &optional params callback)
  "Send a request frame with METHOD and PARAMS.
If CALLBACK is provided, it will be called with the response."
  (unless openclaw--websocket
    (error "Not connected to OpenClaw gateway"))
  (unless openclaw--handshake-complete
    (error "Gateway handshake not complete"))
  (let* ((id (openclaw--next-request-id))
         (request `((type . "req")
                    (id . ,id)
                    (method . ,method)
                    ,@(when params `((params . ,params))))))
    (when callback
      (puthash id callback openclaw--pending-requests))
    (websocket-send-text openclaw--websocket (json-encode request))
    id))

(defun openclaw--handle-response (response)
  "Handle a response frame from the gateway."
  (let* ((data (json-read-from-string response))
         (id (alist-get 'id data))
         (payload (alist-get 'payload data))
         (result (alist-get 'result payload))
         (error (alist-get 'error payload))
         (callback (gethash id openclaw--pending-requests)))
    (when callback
      (remhash id openclaw--pending-requests)
      (funcall callback (or result error payload)))))

(defun openclaw--send-connect ()
  "Send connect request after receiving challenge."
  (unless openclaw--connect-nonce
    (error "No nonce from gateway"))
  (let* ((auth (cond
                (openclaw-gateway-token
                 `((token . ,openclaw-gateway-token)))
                (openclaw-gateway-password
                 `((password . ,openclaw-gateway-password)))
                (t nil)))
         (id (openclaw--uuid))
         (params `((minProtocol . 3)
                   (maxProtocol . 3)
                   (client . ((id . "gateway-client")
                              (displayName . "openclaw.el")
                              (version . "0.1.0")
                              (platform . ,system-type)
                              (mode . "backend")))
                   (caps . [])
                   (role . "operator")
                   (scopes . ["operator.admin"])
                   ,@(when auth `((auth . ,auth)))))
         (connect-frame `((type . "req")
                          (id . ,id)
                          (method . "connect")
                          (params . ,params))))
    (puthash id (lambda (result)
                  (message "Connected to OpenClaw!")
                  (setq openclaw--handshake-complete t)
                  (openclaw--fetch-sessions))
            openclaw--pending-requests)
    (websocket-send-text openclaw--websocket (json-encode connect-frame))))

(defun openclaw--handle-event (event)
  "Handle an EVENT notification from the gateway."
  (let* ((data (json-read-from-string event))
         (event-type (alist-get 'event data))
         (payload (alist-get 'payload data)))
    (pcase event-type
      ("connect.challenge"
       (let ((nonce (alist-get 'nonce payload)))
         (message "Received connect challenge")
         (setq openclaw--connect-nonce nonce)
         (openclaw--send-connect)))
      (_
       (let ((method (alist-get 'method data))
             (params (alist-get 'params data)))
         (pcase method
           ("chat.message"
            (openclaw--handle-chat-message params))
           ("sessions.update"
            (openclaw--handle-sessions-update params))
           (_
            (message "OpenClaw event: %s" (or event-type method)))))))))

(defun openclaw--on-message (_ws frame)
  "Handle incoming WebSocket message FRAME."
  (let ((payload (websocket-frame-payload frame)))
    (condition-case err
        (let ((data (json-read-from-string payload)))
          (cond
           ;; Event frame (has 'event' key)
           ((alist-get 'event data)
            (openclaw--handle-event payload))
           ;; Response frame (has 'type' = "res" or has 'payload')
           ((or (equal (alist-get 'type data) "res")
                (alist-get 'payload data))
            (openclaw--handle-response payload))
           ;; Request frame (has 'method') - events without 'event' key
           ((alist-get 'method data)
            (openclaw--handle-event payload))
           (t
            nil)))  ; Ignore unknown frames
      (error
       (message "OpenClaw parse error: %s" err)))))

(defun openclaw--on-close (_ws)
  "Handle WebSocket close event."
  (message "OpenClaw connection closed")
  (setq openclaw--websocket nil))

(defun openclaw--on-error (_ws err)
  "Handle WebSocket error ERR."
  (message "OpenClaw connection error: %s" err))

(defun openclaw--on-open (ws)
  "Handle WebSocket open event."
  (message "WebSocket connected, awaiting gateway challenge...")
  (setq openclaw--websocket ws
        openclaw--connect-nonce nil
        openclaw--handshake-complete nil))


;;; Connection Management

;;;###autoload
(defun openclaw-connect (&optional url)
  "Connect to OpenClaw gateway at URL.
If URL is nil, use `openclaw-gateway-url'."
  (interactive)
  (setq url (or url openclaw-gateway-url))
  (when openclaw--websocket
    (openclaw-close-connection))
  
  (message "Connecting to OpenClaw at %s..." url)
  
  ;; Add authentication headers
  (let ((auth-header nil))
    (cond
     (openclaw-gateway-token
      (setq auth-header (cons "Authorization" (format "Bearer %s" openclaw-gateway-token))))
     (openclaw-gateway-password
      (setq auth-header (cons "Authorization" (format "Basic %s" (base64-encode-string 
                                                                   (format "user:%s" openclaw-gateway-password)))))))
    
    (message "Opening websocket...")
    (if auth-header
        (websocket-open
         url
         :custom-header-alist (list auth-header)
         :on-open #'openclaw--on-open
         :on-message #'openclaw--on-message
         :on-close #'openclaw--on-close
         :on-error #'openclaw--on-error)
      (websocket-open
       url
       :on-open #'openclaw--on-open
       :on-message #'openclaw--on-message
       :on-close #'openclaw--on-close
       :on-error #'openclaw--on-error))))

(defun openclaw-close-connection ()
  "Close the connection to OpenClaw gateway."
  (interactive)
  (when openclaw--websocket
    (websocket-close openclaw--websocket)
    (setq openclaw--websocket nil)
    (message "Disconnected from OpenClaw")))

(defun openclaw-connected-p ()
  "Return non-nil if connected to gateway."
  (and openclaw--websocket
       (websocket-openp openclaw--websocket)))


;;; Session Management

(defun openclaw--fetch-sessions ()
  "Fetch the list of sessions from the gateway."
  (when (openclaw-connected-p)
    (openclaw--make-request
     "sessions.list"
     '((limit . 50))
     (lambda (result)
       (clrhash openclaw--sessions)
       ;; Result is an alist with 'sessions' key containing a vector
       (let* ((sessions-raw (alist-get 'sessions result))
              (sessions (if (vectorp sessions-raw)
                            (append sessions-raw nil)
                          (list sessions-raw))))
         (dolist (session sessions)
           (let ((key (alist-get 'key session)))
             (when key
               (puthash key session openclaw--sessions))))
         (message "Loaded %d OpenClaw sessions" (hash-table-count openclaw--sessions)))))))

(defun openclaw-list-sessions ()
  "Display list of OpenClaw sessions."
  (interactive)
  (if (not (openclaw-connected-p))
      (message "Not connected to OpenClaw")
    (openclaw--make-request
     "sessions.list"
     '((limit . 50))
     (lambda (result)
       (let ((buf (get-buffer-create "*openclaw-sessions*")))
         (with-current-buffer buf
           (setq buffer-read-only nil)
           (erase-buffer)
           (insert "OpenClaw Sessions\n")
           (insert "=================\n\n")
           (let* ((sessions-raw (alist-get 'sessions result))
                  (sessions (if (vectorp sessions-raw) (append sessions-raw nil) sessions-raw)))
             (dolist (session sessions)
               (let* ((key (alist-get 'key session))
                      (label (or (alist-get 'label session) 
                                (alist-get 'displayName session)
                                key))
                      (agent (alist-get 'agentId session)))
                 (insert-button label
                               'action (lambda (_) (openclaw--switch-to-session key))
                               'follow-link t)
                 (insert (format " [%s]\n" agent)))))
           (setq buffer-read-only t)
           (goto-char (point-min))
           (display-buffer buf)))))))

(defun openclaw--switch-to-session (session-key)
  "Switch to or create buffer for SESSION-KEY."
  (let* ((session-info (gethash session-key openclaw--sessions))
         (label (or (alist-get 'label session-info)
                   (alist-get 'displayName session-info)
                   session-key))
         (buf-name (format openclaw-session-buffer-name label))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (openclaw-chat-mode)
      (setq-local openclaw--current-session session-key)
      (setq-local openclaw--session-label label)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Session: %s\n" label))
        (insert "Loading history...\n\n")))
    (switch-to-buffer buf)
    (openclaw--fetch-history session-key)))

(defun openclaw-switch-session ()
  "Interactively switch to an OpenClaw session."
  (interactive)
  (if (hash-table-empty-p openclaw--sessions)
      (message "No sessions available. Connect first.")
    (let ((sessions (hash-table-keys openclaw--sessions)))
      (let ((choice (completing-read "Session: " sessions nil t)))
        (openclaw--switch-to-session choice)))))

(defun openclaw-new-chat ()
  "Start a new chat session."
  (interactive)
  (let ((buf (generate-new-buffer (format openclaw-session-buffer-name "new"))))
    (with-current-buffer buf
      (openclaw-chat-mode)
      (insert "Welcome to OpenClaw!\n")
      (insert "Type your message and press C-c C-c to send.\n\n"))
    (switch-to-buffer buf)))


;;; Chat Functions

(defun openclaw--fetch-history (session-key)
  "Fetch chat history for SESSION-KEY."
  (openclaw--make-request
   "chat.history"
   `((sessionKey . ,session-key)
     (limit . 100))
   (lambda (result)
     ;; Find the buffer for this session by checking buffer-local variable
     (let ((target-buf nil))
       (dolist (buf (buffer-list))
         (with-current-buffer buf
           (when (and (eq major-mode 'openclaw-chat-mode)
                      (equal openclaw--current-session session-key))
             (setq target-buf buf))))
       (when target-buf
         (with-current-buffer target-buf
           (let* ((messages-raw (alist-get 'messages result))
                  (messages (if (vectorp messages-raw) (append messages-raw nil) messages-raw))
                  (inhibit-read-only t))
             (erase-buffer)
             (when openclaw--session-label
               (insert (format "Session: %s\n\n" openclaw--session-label)))
             (if (or (not messages) (null messages))
                 (insert "No messages yet. Type your message and press C-c C-c to send.\n\n")
               (dolist (msg messages)
                 (let* ((role (alist-get 'role msg))
                        (content-raw (alist-get 'content msg))
                        (timestamp (alist-get 'timestamp msg))
                        ;; Extract text from content (can be string or vector of parts)
                        (content-text
                         (cond
                          ((stringp content-raw) content-raw)
                          ((vectorp content-raw)
                           ;; Content is array of parts, extract text from each
                           (mapconcat
                            (lambda (part)
                              (let ((part-type (alist-get 'type part))
                                    (part-text (alist-get 'text part)))
                                (cond
                                 ((equal part-type 'text) (or part-text ""))
                                 ((stringp part) part)
                                 (t ""))))
                            (append content-raw nil)
                            "\n"))
                          (t (format "%s" content-raw)))))
                   (insert (format "[%s] %s: %s\n"
                                   (or timestamp "")
                                   (if (symbolp role) (capitalize (symbol-name role)) role)
                                   content-text))))
             (goto-char (point-max)))))))))

(defun openclaw--handle-chat-message (params)
  "Handle incoming chat message PARAMS."
  (let* ((session-key (alist-get 'sessionKey params))
         (role (alist-get 'role params))
         (content-raw (alist-get 'content params))
         ;; Extract text from content
         (content-text
          (cond
           ((stringp content-raw) content-raw)
           ((vectorp content-raw)
            (mapconcat
             (lambda (part)
               (let ((part-type (alist-get 'type part))
                     (part-text (alist-get 'text part)))
                 (cond
                  ((equal part-type 'text) (or part-text ""))
                  ((stringp part) part)
                  (t ""))))
             (append content-raw nil)
             "\n"))
           (t (format "%s" content-raw)))))
    ;; Find buffer for this session and append message
    (cl-dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and (eq major-mode 'openclaw-chat-mode)
                   (equal openclaw--current-session session-key))
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert (format "\n[%s]: %s\n"
                            (if (symbolp role) (capitalize (symbol-name role)) role)
                            content-text))
            (cl-return)))))))

(defun openclaw--handle-sessions-update (params)
  "Handle sessions update PARAMS."
  (openclaw--fetch-sessions))

(defun openclaw-send-message ()
  "Send message to current session."
  (interactive)
  (unless (eq major-mode 'openclaw-chat-mode)
    (error "Not in an OpenClaw chat buffer"))
  (unless openclaw--current-session
    (error "No active session"))
  
  ;; Get message from minibuffer
  (let ((msg (read-string "Message: ")))
    (when (string-empty-p msg)
      (error "Empty message"))
    
    ;; Insert message into buffer immediately
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (format "[You]: %s\n" msg))
      (goto-char (point-max)))
    
    ;; Send to gateway
    (openclaw--make-request
     "chat.send"
     `((sessionKey . ,openclaw--current-session)
       (message . ,msg))
     (lambda (result)
       ;; Message sent successfully - response will come via event
       (when (and (not (null result)) (alist-get 'error result))
         (message "Send error: %s" (alist-get 'error result)))))))

(defun openclaw-show-history ()
  "Show chat history for current session."
  (interactive)
  (when openclaw--current-session
    (openclaw--fetch-history openclaw--current-session)))


;;; Slash Commands

(defun openclaw-slash-command (cmd)
  "Execute slash command CMD in current session."
  (interactive "sCommand: ")
  (unless (string-prefix-p "/" cmd)
    (setq cmd (concat "/" cmd)))
  (openclaw--make-request
   "chat.send"
   `((sessionKey . ,openclaw--current-session)
     (message . ,cmd))
   (lambda (result)
     (message "Command sent: %s" cmd))))


;;; Help

(defun openclaw-help ()
  "Show OpenClaw help."
  (interactive)
  (let ((help-buf (get-buffer-create "*openclaw-help*")))
    (with-current-buffer help-buf
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert "OpenClaw Emacs Interface Help
================================

Quick Start:
  M-x openclaw-connect     - Connect to gateway
  M-x openclaw-chat        - Start a new chat
  M-x openclaw-list-sessions - List available sessions

In Chat Mode:
  RET / C-c C-c  - Send message
  C-c C-l        - List sessions
  C-c C-s        - Switch session
  C-c C-q        - Close connection

Leader Keys (after C-c):
  c - Connect
  C - Close connection
  l - List sessions
  s - Switch session
  n - New chat
  m - Send message
  h - Show history
  ? - Help

Slash Commands:
  /status  - Show session status
  /clear   - Clear chat
  /model   - Change model
  /help    - Show gateway help
")
      (setq buffer-read-only t)
      (goto-char (point-min)))
    (display-buffer help-buf)))


;;; Entry Points

;;;###autoload
(defun openclaw-chat ()
  "Start chatting with OpenClaw."
  (interactive)
  (unless (openclaw-connected-p)
    (openclaw-connect))
  (openclaw-new-chat))

;;;###autoload
(defalias 'openclaw 'openclaw-connect
  "Connect to OpenClaw gateway.")

(provide 'openclaw)

;;; openclaw.el ends here
