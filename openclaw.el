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

(defvar openclaw--current-session nil
  "Currently active session key.")

(defvar openclaw--message-history nil
  "List of recent messages for display.")

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
  (setq-local openclaw--current-session nil))


;;; WebSocket Communication

(defun openclaw--next-request-id ()
  "Generate the next request ID."
  (cl-incf openclaw--request-id))

(defun openclaw--make-request (method &optional params callback)
  "Send a JSON-RPC request with METHOD and PARAMS.
If CALLBACK is provided, it will be called with the response."
  (unless openclaw--websocket
    (error "Not connected to OpenClaw gateway"))
  (let* ((id (openclaw--next-request-id))
         (request `((jsonrpc . "2.0")
                    (id . ,id)
                    (method . ,method)
                    ,@(when params `((params . ,params))))))
    (when callback
      (puthash id callback openclaw--pending-requests))
    (websocket-send-text openclaw--websocket (json-encode request))
    id))

(defun openclaw--handle-response (response)
  "Handle a JSON-RPC RESPONSE from the gateway."
  (let* ((data (json-read-from-string response))
         (id (alist-get 'id data))
         (result (alist-get 'result data))
         (error (alist-get 'error data))
         (callback (gethash id openclaw--pending-requests)))
    (when callback
      (remhash id openclaw--pending-requests)
      (funcall callback (or result error)))))

(defun openclaw--handle-event (event)
  "Handle an EVENT notification from the gateway."
  (let* ((data (json-read-from-string event))
         (method (alist-get 'method data))
         (params (alist-get 'params data)))
    (pcase method
      ("chat.message"
       (openclaw--handle-chat-message params))
      ("sessions.update"
       (openclaw--handle-sessions-update params))
      (_
       (message "OpenClaw event: %s" method)))))

(defun openclaw--on-message (_ws frame)
  "Handle incoming WebSocket message FRAME."
  (let ((payload (websocket-frame-payload frame)))
    (condition-case err
        (let ((data (json-read-from-string payload)))
          (if (alist-get 'method data)
              (openclaw--handle-event payload)
            (openclaw--handle-response payload)))
      (error
       (message "OpenClaw parse error: %s" err)))))

(defun openclaw--on-close (_ws)
  "Handle WebSocket close event."
  (setq openclaw--websocket nil)
  (message "OpenClaw connection closed"))

(defun openclaw--on-error (_ws err)
  "Handle WebSocket error ERR."
  (message "OpenClaw connection error: %s" err))


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
  
  (let ((headers nil))
    ;; Add authentication headers
    (cond
     (openclaw-gateway-token
      (push (cons "Authorization" (format "Bearer %s" openclaw-gateway-token)) headers))
     (openclaw-gateway-password
      (push (cons "Authorization" (format "Basic %s" (base64-encode-string 
                                                       (format "user:%s" openclaw-gateway-password)))) headers)))
    
    (websocket-open
     url
     :custom-header-alist headers
     :on-open (lambda (_ws)
                (setq openclaw--websocket _ws)
                (message "Connected to OpenClaw")
                (openclaw--fetch-sessions))
     :on-message #'openclaw--on-message
     :on-close #'openclaw--on-close
     :on-error #'openclaw--on-error)))

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
       (dolist (session (alist-get 'sessions result))
         (let ((key (alist-get 'sessionKey session)))
           (puthash key session openclaw--sessions)))
       (message "Loaded %d sessions" (hash-table-count openclaw--sessions))))))

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
           (dolist (session (alist-get 'sessions result))
             (let* ((key (alist-get 'sessionKey session))
                    (label (or (alist-get 'label session) key))
                    (agent (alist-get 'agentId session)))
               (insert-button label
                             'action (lambda (_) (openclaw--switch-to-session key))
                             'follow-link t)
               (insert (format " [%s]\n" agent))))
           (setq buffer-read-only t)
           (goto-char (point-min))
           (display-buffer buf)))))))

(defun openclaw--switch-to-session (session-key)
  "Switch to or create buffer for SESSION-KEY."
  (let* ((session-info (gethash session-key openclaw--sessions))
         (label (or (alist-get 'label session-info) session-key))
         (buf-name (format openclaw-session-buffer-name label))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (openclaw-chat-mode)
      (setq-local openclaw--current-session session-key)
      (setq-local openclaw--message-history nil)
      (openclaw--fetch-history session-key))
    (switch-to-buffer buf)))

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
     (let ((messages (alist-get 'messages result)))
       (openclaw--display-messages messages)))))

(defun openclaw--display-messages (messages)
  "Display MESSAGES in current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (dolist (msg messages)
      (let* ((role (alist-get 'role msg))
             (content (alist-get 'content msg))
             (timestamp (alist-get 'timestamp msg)))
        (insert (format "[%s] %s: %s\n"
                        (or timestamp "")
                        (capitalize (symbol-name role))
                        content))))
    (goto-char (point-max))))

(defun openclaw--handle-chat-message (params)
  "Handle incoming chat message PARAMS."
  (let* ((session-key (alist-get 'sessionKey params))
         (role (alist-get 'role params))
         (content (alist-get 'content params)))
    ;; Find buffer for this session and append message
    (cl-dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and (eq major-mode 'openclaw-chat-mode)
                   (equal openclaw--current-session session-key))
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert (format "\n[%s]: %s\n"
                            (capitalize (symbol-name role))
                            content))
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
  (let ((message (read-string "Message: ")))
    (when (string-empty-p message)
      (error "Empty message"))
    
    ;; Send to gateway
    (openclaw--make-request
     "chat.send"
     `((sessionKey . ,openclaw--current-session)
       (message . ,message))
     (lambda (result)
       ;; Message sent, response will come via event
       (message "Message sent")))
    
    ;; Show in buffer immediately
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (format "\n[You]: %s\n" message)))))

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
