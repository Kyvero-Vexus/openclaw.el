;;; openclaw.el --- Emacs interface to OpenClaw -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Kyvero Vexus Corporation

;; Author: Kyvero Vexus <contact@kyverovexus.org>
;; URL: https://github.com/Kyvero-Vexus/openclaw.el
;; Keywords: comm tools ai
;; Version: 0.2.0
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

;; This package provides an Emacs interface to OpenClaw with TUI feature parity.
;;
;; Quick start:
;;   M-x openclaw-connect RET
;;   M-x openclaw-chat RET
;;
;; Keybindings (when in openclaw-chat-mode):
;;   C-c C-c   - Send message
;;   C-c C-l   - List sessions
;;   C-c C-s   - Switch session
;;   C-c C-n   - New chat
;;   C-c C-a   - Abort current run
;;   C-c C-m   - Model picker
;;   C-c C-p   - Session picker
;;   C-c C-h   - Show history
;;   C-c C-q   - Close connection

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
If nil, will attempt to read from config file, then prompt."
  :type '(choice (const nil) string)
  :group 'openclaw)

(defcustom openclaw-gateway-password nil
  "Password for the OpenClaw gateway.
Used if token is not set."
  :type '(choice (const nil) string)
  :group 'openclaw)

(defcustom openclaw-config-file "~/.openclaw/openclaw.json"
  "Path to OpenClaw configuration file."
  :type 'string
  :group 'openclaw)

(defcustom openclaw-default-session "main"
  "Default session key to connect to."
  :type 'string
  :group 'openclaw)

(defcustom openclaw-session-buffer-name "*openclaw:%s*"
  "Format string for session buffer names."
  :type 'string
  :group 'openclaw)

(defcustom openclaw-history-limit 200
  "Number of history messages to load."
  :type 'integer
  :group 'openclaw)


;;; Faces

(defface openclaw-user-face
  '((t :foreground "cyan" :weight bold))
  "Face for user messages."
  :group 'openclaw)

(defface openclaw-assistant-face
  '((t :foreground "green"))
  "Face for assistant messages."
  :group 'openclaw)

(defface openclaw-system-face
  '((t :foreground "yellow" :slant italic))
  "Face for system messages."
  :group 'openclaw)

(defface openclaw-tool-face
  '((t :foreground "magenta"))
  "Face for tool output."
  :group 'openclaw)

(defface openclaw-timestamp-face
  '((t :foreground "gray60"))
  "Face for timestamps."
  :group 'openclaw)

(defface openclaw-session-header-face
  '((t :foreground "white" :weight bold :underline t))
  "Face for session headers."
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

(defvar openclaw--agents nil
  "List of available agent info alists.")

(defvar openclaw--current-agent "main"
  "Currently active agent ID.")

(defvar openclaw--connect-nonce nil
  "Nonce from gateway connect challenge.")

(defvar openclaw--handshake-complete nil
  "Non-nil when gateway handshake is complete.")

(defvar openclaw--mode-line-string ""
  "String shown in mode-line for OpenClaw state.")

(defvar-local openclaw--current-session nil
  "Currently active session key (buffer-local).")

(defvar-local openclaw--session-label nil
  "Display label for current session (buffer-local).")

(defvar-local openclaw--message-history nil
  "List of recent messages for display (buffer-local).")


;;; Keymaps

(defvar openclaw-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'openclaw-send-message)
    (define-key map (kbd "C-c C-c") #'openclaw-send-message)
    (define-key map (kbd "C-c C-l") #'openclaw-list-sessions)
    (define-key map (kbd "C-c C-s") #'openclaw-switch-session)
    (define-key map (kbd "C-c C-n") #'openclaw-new-chat)
    (define-key map (kbd "C-c C-a") #'openclaw-abort)
    (define-key map (kbd "C-c C-m") #'openclaw-model-picker)
    (define-key map (kbd "C-c C-p") #'openclaw-session-picker)
    (define-key map (kbd "C-c C-h") #'openclaw-show-history)
    (define-key map (kbd "C-c C-q") #'openclaw-close-connection)
    (define-key map (kbd "C-c C-t") #'openclaw-toggle-thinking)
    (define-key map (kbd "C-c C-o") #'openclaw-toggle-tool-output)
    (define-key map (kbd "C-c ?") #'openclaw-help)
    map)
  "Keymap for `openclaw-chat-mode'.")

(defvar openclaw-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'openclaw-send-message)
    (define-key map (kbd "C-c C-l") #'openclaw-list-sessions)
    (define-key map (kbd "C-c C-s") #'openclaw-switch-session)
    (define-key map (kbd "C-c C-n") #'openclaw-new-chat)
    (define-key map (kbd "C-c C-q") #'openclaw-close-connection)
    (define-key map (kbd "C-c C-h") #'openclaw-show-history)
    (define-key map (kbd "C-c ?") #'openclaw-help)
    ;; Leader-style single-letter bindings
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


;;; Major Modes

(define-derived-mode openclaw-mode fundamental-mode "OpenClaw"
  "Major mode for OpenClaw interaction.
\\{openclaw-mode-map}"
  :group 'openclaw
  (buffer-disable-undo)
  (setq buffer-read-only t))

(define-derived-mode openclaw-chat-mode fundamental-mode "OpenClaw-Chat"
  "Major mode for chatting with OpenClaw sessions.
\\{openclaw-chat-mode-map}"
  :group 'openclaw
  (buffer-disable-undo)
  (setq-local openclaw--current-session nil)
  (setq-local openclaw--session-label nil)
  (openclaw--update-mode-line))


;;; Utilities

(defun openclaw--uuid ()
  "Generate a random UUID v4 string."
  (format "%04x%04x-%04x-%04x-%04x-%04x%04x%04x"
          (random 65535) (random 65535)
          (random 65535)
          (logior 16384 (random 4096))  ; version 4
          (logior 32768 (random 16384)) ; variant 1
          (random 65535) (random 65535) (random 65535)))

(defun openclaw--next-request-id ()
  "Generate the next request ID (UUID)."
  (openclaw--uuid))

(defun openclaw--idempotency-key ()
  "Generate idempotency key for chat.send requests."
  (openclaw--uuid))

(defun openclaw--read-config-token ()
  "Read gateway token from OpenClaw config file.
Returns token string or nil."
  (let ((config-path (expand-file-name openclaw-config-file)))
    (when (file-readable-p config-path)
      (condition-case nil
          (let* ((json-object-type 'alist)
                 (json-array-type 'vector)
                 (config (json-read-file config-path))
                 (gateway (alist-get 'gateway config))
                 (auth (alist-get 'auth gateway)))
            (alist-get 'token auth))
        (error nil)))))

(defun openclaw--effective-token ()
  "Return the effective gateway token.
Checks customization variable first, then config file."
  (or openclaw-gateway-token
      (openclaw--read-config-token)))

(defun openclaw--format-timestamp (ts)
  "Format timestamp TS for display.
TS can be a string (ISO 8601) or number (epoch ms)."
  (cond
   ((and (stringp ts) (string-match "T\\([0-9][0-9]:[0-9][0-9]\\)" ts))
    (format "[%s]" (match-string 1 ts)))
   ((numberp ts)
    (format-time-string "[%H:%M]" (seconds-to-time (/ ts 1000.0))))
   ((stringp ts)
    (format "[%s]" (substring ts 0 (min 16 (length ts)))))
   (t "")))


;;; Mode Line

(defun openclaw--update-mode-line ()
  "Update the mode-line string for OpenClaw."
  (setq openclaw--mode-line-string
        (if (openclaw-connected-p)
            (format " OC[%s/%s]"
                    openclaw--current-agent
                    (or openclaw--current-session openclaw-default-session))
          " OC[disconnected]")))


;;; WebSocket Communication

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
  "Handle a response frame from the gateway.
RESPONSE is the raw JSON string."
  (let* ((data (json-read-from-string response))
         (id (alist-get 'id data))
         (ok (alist-get 'ok data))
         (payload (alist-get 'payload data))
         (top-error (alist-get 'error data))
         (result (and (listp payload) (alist-get 'result payload)))
         (payload-error (and (listp payload) (alist-get 'error payload)))
         (callback (gethash id openclaw--pending-requests))
         (value (cond
                 ((and (assq 'ok data) (eq ok :json-false)) `((error . ,top-error)))
                 (top-error `((error . ,top-error)))
                 (payload-error `((error . ,payload-error)))
                 (result result)
                 (t payload))))
    (when callback
      (remhash id openclaw--pending-requests)
      (funcall callback value))))

(defun openclaw--send-connect ()
  "Send connect request after receiving challenge."
  (unless openclaw--connect-nonce
    (error "No nonce from gateway"))
  (let* ((token (openclaw--effective-token))
         (auth (cond
                (token `((token . ,token)))
                (openclaw-gateway-password
                 `((password . ,openclaw-gateway-password)))
                (t nil)))
         (id (openclaw--uuid))
         (params `((minProtocol . 3)
                   (maxProtocol . 3)
                   (client . ((id . "gateway-client")
                              (displayName . "openclaw.el")
                              (version . "0.2.0")
                              (platform . ,(symbol-name system-type))
                              (mode . "backend")))
                   (caps . [])
                   (role . "operator")
                   (scopes . ["operator.admin"])
                   ,@(when auth `((auth . ,auth)))))
         (connect-frame `((type . "req")
                          (id . ,id)
                          (method . "connect")
                          (params . ,params))))
    (puthash id (lambda (_result)
                  (setq openclaw--handshake-complete t)
                  (message "Connected to OpenClaw gateway!")
                  (openclaw--update-mode-line)
                  (openclaw--fetch-sessions))
            openclaw--pending-requests)
    (websocket-send-text openclaw--websocket (json-encode connect-frame))))

(defun openclaw--handle-event (event)
  "Handle an EVENT notification from the gateway.
EVENT is the raw JSON string."
  (let* ((data (json-read-from-string event))
         (event-type (alist-get 'event data))
         (payload (alist-get 'payload data)))
    (pcase event-type
      ("connect.challenge"
       (let ((nonce (alist-get 'nonce payload)))
         (setq openclaw--connect-nonce nonce)
         (openclaw--send-connect)))
      ("chat"
       (let ((session-key (or (alist-get 'sessionKey payload)
                              (alist-get 'session_key payload))))
         (when (and (stringp session-key) (> (length session-key) 0))
           (openclaw--fetch-history session-key))))
      (_
       (let ((method (alist-get 'method data))
             (params (alist-get 'params data)))
         (pcase method
           ("chat.message" (openclaw--handle-chat-message params))
           ("sessions.update" (openclaw--handle-sessions-update params))
           (_ nil)))))))

(defun openclaw--on-message (_ws frame)
  "Handle incoming WebSocket message FRAME."
  (let ((payload (websocket-frame-payload frame)))
    (when (and payload (stringp payload) (> (length payload) 0))
      ;; Some gateway/tooling paths can emit non-JSON text frames. Ignore those.
      (if (not (string-match-p "\\`[[:space:]]*[\\[{]" payload))
          nil
        (condition-case err
            (let ((data (json-read-from-string payload)))
              (cond
               ;; Event frame (has 'event' key)
               ((alist-get 'event data)
                (openclaw--handle-event payload))
               ;; Response frame
               ((or (equal (alist-get 'type data) "res")
                    (alist-get 'payload data))
                (openclaw--handle-response payload))
               ;; Request frame (method-based events)
               ((alist-get 'method data)
                (openclaw--handle-event payload))
               (t nil)))
          (json-readtable-error nil)
          (error
           (message "OpenClaw parse error: %s" err)))))))

(defun openclaw--on-close (_ws)
  "Handle WebSocket close event."
  (message "OpenClaw connection closed")
  (setq openclaw--websocket nil
        openclaw--handshake-complete nil)
  (openclaw--update-mode-line))

(defun openclaw--on-error (_ws err)
  "Handle WebSocket error ERR."
  (message "OpenClaw connection error: %s" err))

(defun openclaw--on-open (ws)
  "Handle WebSocket open event for WS."
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

  (let ((ws (websocket-open
             url
             :on-open #'openclaw--on-open
             :on-message #'openclaw--on-message
             :on-close #'openclaw--on-close
             :on-error #'openclaw--on-error)))
    (setq openclaw--websocket ws)))

(defun openclaw-close-connection ()
  "Close the connection to OpenClaw gateway."
  (interactive)
  (when openclaw--websocket
    (websocket-close openclaw--websocket)
    (setq openclaw--websocket nil
          openclaw--handshake-complete nil)
    (openclaw--update-mode-line)
    (message "Disconnected from OpenClaw")))

(defun openclaw-connected-p ()
  "Return non-nil if connected to gateway."
  (and openclaw--websocket
       (websocket-openp openclaw--websocket)))


;;; Session Management

(defun openclaw--fetch-sessions ()
  "Fetch the list of sessions from the gateway."
  (when (and (openclaw-connected-p) openclaw--handshake-complete)
    (openclaw--make-request
     "sessions.list"
     '((limit . 50))
     (lambda (result)
       (clrhash openclaw--sessions)
       (let* ((sessions-raw (alist-get 'sessions result))
              (sessions (if (vectorp sessions-raw)
                            (append sessions-raw nil)
                          (when sessions-raw (list sessions-raw)))))
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
           (insert (propertize "OpenClaw Sessions\n" 'face 'openclaw-session-header-face))
           (insert "=================\n\n")
           (let* ((sessions-raw (alist-get 'sessions result))
                  (sessions (if (vectorp sessions-raw) (append sessions-raw nil) sessions-raw)))
             (if (null sessions)
                 (insert "No sessions found.\n")
               (dolist (session sessions)
                 (let* ((key (alist-get 'key session))
                        (label (or (alist-get 'label session)
                                  (alist-get 'displayName session)
                                  key))
                        (agent (or (alist-get 'agentId session) "?")))
                   (insert-button label
                                 'action (lambda (_) (openclaw--switch-to-session key))
                                 'follow-link t)
                   (insert (format " [agent:%s]\n" agent))))))
           (setq buffer-read-only t)
           (goto-char (point-min))
           (display-buffer buf)))))))

(defun openclaw--switch-to-session (session-key)
  "Switch to or create buffer for SESSION-KEY."
  (let* ((session-info (gethash session-key openclaw--sessions))
         (label (or (and session-info
                        (or (alist-get 'label session-info)
                            (alist-get 'displayName session-info)))
                   session-key))
         (buf-name (format openclaw-session-buffer-name label))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (unless (eq major-mode 'openclaw-chat-mode)
        (openclaw-chat-mode))
      (setq-local openclaw--current-session session-key)
      (setq-local openclaw--session-label label)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "Session: %s\n" label)
                            'face 'openclaw-session-header-face))
        (insert "Loading history...\n\n"))
      (openclaw--update-mode-line))
    (switch-to-buffer buf)
    (when openclaw--handshake-complete
      (openclaw--fetch-history session-key))))

(defun openclaw-switch-session ()
  "Interactively switch to an OpenClaw session."
  (interactive)
  (if (hash-table-empty-p openclaw--sessions)
      (message "No sessions available. Connect first.")
    (let* ((sessions (hash-table-keys openclaw--sessions))
           (choice (completing-read "Session: " sessions nil t)))
      (openclaw--switch-to-session choice))))

(defun openclaw-session-picker ()
  "Pick a session interactively (TUI Ctrl+P equivalent)."
  (interactive)
  (openclaw-switch-session))

(defun openclaw-new-chat ()
  "Start a new chat session."
  (interactive)
  (let ((buf (generate-new-buffer (format openclaw-session-buffer-name "new"))))
    (with-current-buffer buf
      (openclaw-chat-mode)
      (let ((inhibit-read-only t))
        (insert (propertize "Welcome to OpenClaw!\n" 'face 'openclaw-session-header-face))
        (insert "Type your message and press C-c C-c to send.\n\n")))
    (switch-to-buffer buf)))


;;; Agent Management

(defun openclaw-list-agents ()
  "List available agents."
  (interactive)
  (if (not (openclaw-connected-p))
      (message "Not connected to OpenClaw")
    (openclaw--make-request
     "agents.list"
     nil
     (lambda (result)
       (let* ((agents-raw (or (alist-get 'agents result) result))
              (agents (if (vectorp agents-raw) (append agents-raw nil) agents-raw)))
         (setq openclaw--agents agents)
         (let ((buf (get-buffer-create "*openclaw-agents*")))
           (with-current-buffer buf
             (setq buffer-read-only nil)
             (erase-buffer)
             (insert (propertize "OpenClaw Agents\n" 'face 'openclaw-session-header-face))
             (insert "===============\n\n")
             (if (null agents)
                 (insert "No agents found.\n")
               (dolist (agent agents)
                 (let ((id (or (alist-get 'id agent)
                              (alist-get 'agentId agent)
                              "unknown")))
                   (insert-button id
                                 'action (lambda (_) (openclaw-switch-agent id))
                                 'follow-link t)
                   (insert "\n"))))
             (setq buffer-read-only t)
             (goto-char (point-min)))
           (display-buffer buf)))))))

(defun openclaw-switch-agent (agent-id)
  "Switch to AGENT-ID."
  (interactive "sAgent ID: ")
  (setq openclaw--current-agent agent-id)
  (openclaw--update-mode-line)
  (openclaw--fetch-sessions)
  (message "Switched to agent: %s" agent-id))


;;; Chat Functions

(defun openclaw--oct-digit-p (ch)
  "Return non-nil if CH is an octal digit character code."
  (and (integerp ch) (>= ch ?0) (<= ch ?7)))

(defun openclaw--decode-octal-escapes (s)
  "Decode octal byte escapes in string S (e.g. \\342\\200\\231) as UTF-8."
  (let* ((len (length s))
         (i 0)
         (bytes '())
         (changed nil))
    (while (< i len)
      (let ((c (aref s i)))
        (if (and (= c ?\\)
                 (<= (+ i 3) (1- len))
                 (openclaw--oct-digit-p (aref s (1+ i)))
                 (openclaw--oct-digit-p (aref s (+ i 2)))
                 (openclaw--oct-digit-p (aref s (+ i 3))))
            (progn
              (push (string-to-number (substring s (1+ i) (+ i 4)) 8) bytes)
              (setq i (+ i 4)
                    changed t))
          (push c bytes)
          (setq i (1+ i)))))
    (if (not changed)
        s
      (condition-case nil
          (decode-coding-string (apply #'unibyte-string (nreverse bytes)) 'utf-8 t)
        (error s)))))

(defun openclaw--normalize-text (s)
  "Normalize string S for display."
  (if (not (stringp s))
      ""
    (let ((out (openclaw--decode-octal-escapes s)))
      (when (and (stringp out) (not (multibyte-string-p out)))
        (setq out
              (condition-case nil
                  (decode-coding-string out 'utf-8 t)
                (error out))))
      out)))

(defun openclaw--content->text (content)
  "Convert CONTENT payload into displayable text."
  (cond
   ((stringp content) (openclaw--normalize-text content))
   ;; CONTENT as a single part object: ((type . "text") (text . "..."))
   ((and (listp content)
         (or (alist-get 'type content) (alist-get 'text content)))
    (let ((ptext (alist-get 'text content)))
      (if (stringp ptext) (openclaw--normalize-text ptext) "")))
   ;; CONTENT as list of parts
   ((listp content)
    (mapconcat #'openclaw--content->text content "\n"))
   ((vectorp content)
    (mapconcat #'openclaw--content->text (append content nil) "\n"))
   (t "")))

(defun openclaw--role-face (role)
  "Return the face for message ROLE."
  (let ((r (if (symbolp role) (symbol-name role) role)))
    (pcase r
      ("user" 'openclaw-user-face)
      ("assistant" 'openclaw-assistant-face)
      ("system" 'openclaw-system-face)
      ("tool" 'openclaw-tool-face)
      (_ 'default))))

(defun openclaw--role-label (role)
  "Return display label for ROLE."
  (let ((r (if (symbolp role) (symbol-name role) role)))
    (pcase r
      ("user" "You")
      ("assistant" "Assistant")
      ("system" "System")
      ("tool" "Tool")
      (_ (capitalize r)))))

(defun openclaw--fetch-history (session-key)
  "Fetch chat history for SESSION-KEY."
  (when openclaw--handshake-complete
    (openclaw--make-request
     "chat.history"
     `((sessionKey . ,session-key)
       (limit . ,openclaw-history-limit))
     (lambda (result)
       (let ((target-buf nil))
         (dolist (buf (buffer-list))
           (with-current-buffer buf
             (when (and (eq major-mode 'openclaw-chat-mode)
                        (equal openclaw--current-session session-key))
               (setq target-buf buf))))
         (when target-buf
           (with-current-buffer target-buf
             (let* ((messages-raw (alist-get 'messages result))
                    (messages (if (vectorp messages-raw)
                                  (append messages-raw nil)
                                messages-raw))
                    (inhibit-read-only t))
               (erase-buffer)
               (when openclaw--session-label
                 (insert (propertize (format "Session: %s\n\n"
                                             openclaw--session-label)
                                     'face 'openclaw-session-header-face)))
               (if (or (not messages) (null messages))
                   (insert "No messages yet. Press C-c C-c to send a message.\n\n")
                 (dolist (msg messages)
                   (let* ((role (alist-get 'role msg))
                          (timestamp (alist-get 'timestamp msg))
                          (content-text (openclaw--content->text
                                        (alist-get 'content msg)))
                          (ts-str (openclaw--format-timestamp timestamp))
                          (role-label (openclaw--role-label role))
                          (role-face (openclaw--role-face role)))
                     (insert (propertize ts-str 'face 'openclaw-timestamp-face))
                     (insert " ")
                     (insert (propertize (format "%s: " role-label)
                                         'face role-face))
                     (insert content-text)
                     (insert "\n"))))
               (goto-char (point-max))))))))))

(defun openclaw--handle-chat-message (params)
  "Handle incoming chat message PARAMS."
  (let* ((session-key (alist-get 'sessionKey params))
         (role (alist-get 'role params))
         (content-text (openclaw--content->text (alist-get 'content params)))
         (role-label (openclaw--role-label role))
         (role-face (openclaw--role-face role)))
    (cl-dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and (eq major-mode 'openclaw-chat-mode)
                   (equal openclaw--current-session session-key))
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert "\n")
            (insert (propertize (format "%s: " role-label) 'face role-face))
            (insert content-text)
            (insert "\n")
            (cl-return)))))))

(defun openclaw--handle-sessions-update (_params)
  "Handle sessions update notification."
  (openclaw--fetch-sessions))

(defun openclaw-send-message ()
  "Send message to current session."
  (interactive)
  (unless (eq major-mode 'openclaw-chat-mode)
    (error "Not in an OpenClaw chat buffer"))
  (unless openclaw--current-session
    (error "No active session"))

  (let ((msg (read-string "Message: ")))
    (when (string-empty-p msg)
      (error "Empty message"))

    ;; Insert user message into buffer
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (propertize "You: " 'face 'openclaw-user-face))
      (insert msg)
      (insert "\n")
      (goto-char (point-max)))

    ;; Send to gateway
    (openclaw--make-request
     "chat.send"
     `((sessionKey . ,openclaw--current-session)
       (message . ,msg)
       (idempotencyKey . ,(openclaw--idempotency-key)))
     (lambda (result)
       (when (and result (listp result) (alist-get 'error result))
         (message "Send error: %s" (alist-get 'error result)))
       ;; Refresh history after brief delay
       (when openclaw--current-session
         (run-at-time 0.3 nil #'openclaw--fetch-history
                      openclaw--current-session))))))

(defun openclaw-show-history ()
  "Show/refresh chat history for current session."
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
     (message . ,cmd)
     (idempotencyKey . ,(openclaw--idempotency-key)))
   (lambda (_result)
     (message "Command sent: %s" cmd))))

(defun openclaw-abort ()
  "Abort the current agent run."
  (interactive)
  (if openclaw--current-session
      (openclaw-slash-command "/abort")
    (message "No active session")))

(defun openclaw-model-picker ()
  "Pick a model (TUI Ctrl+L equivalent)."
  (interactive)
  (if (not (openclaw-connected-p))
      (message "Not connected to OpenClaw")
    (openclaw--make-request
     "models.list"
     nil
     (lambda (result)
       (let* ((models-raw (or (alist-get 'models result) result))
              (models (if (vectorp models-raw) (append models-raw nil) models-raw))
              (names (mapcar (lambda (m)
                              (or (alist-get 'id m)
                                  (alist-get 'name m)
                                  (format "%s" m)))
                            models)))
         (if (null names)
             (message "No models available")
           (let ((choice (completing-read "Model: " names nil t)))
             (when openclaw--current-session
               (openclaw-slash-command (format "/model %s" choice))))))))))

(defun openclaw-toggle-thinking ()
  "Toggle thinking visibility (TUI Ctrl+T equivalent)."
  (interactive)
  (openclaw-slash-command "/think"))

(defun openclaw-toggle-tool-output ()
  "Toggle tool output expansion (TUI Ctrl+O equivalent)."
  (interactive)
  (message "Tool output toggle: not yet implemented for Emacs"))


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

Chat Mode Keybindings:
  RET / C-c C-c  - Send message
  C-c C-l        - List sessions
  C-c C-s        - Switch session
  C-c C-n        - New chat
  C-c C-a        - Abort current run
  C-c C-m        - Model picker
  C-c C-p        - Session picker
  C-c C-h        - Show/refresh history
  C-c C-t        - Toggle thinking
  C-c C-o        - Toggle tool output
  C-c C-q        - Close connection
  C-c ?          - This help

Slash Commands (type in chat):
  /help          - Show gateway help
  /status        - Show session status
  /agent <id>    - Switch agent
  /agents        - List agents
  /session <key> - Switch session
  /sessions      - List sessions
  /model <m>     - Change model
  /models        - List models
  /new           - Reset session
  /abort         - Abort current run
  /deliver <on|off> - Toggle delivery
  /think <level> - Set thinking level
  /verbose <on|off> - Set verbose mode
  /context       - Show context info
  /exit          - Exit/disconnect
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
