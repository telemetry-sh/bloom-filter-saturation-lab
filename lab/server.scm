(define-module (lab server)
  #:use-module (ice-9 textual-ports)
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (web server)
  #:use-module (web uri)
  #:use-module (lab model)
  #:export (main))

(define (environment name fallback)
  (or (getenv name) fallback))

(define (safe-host)
  (let ((host (environment "HOST" "127.0.0.1")))
    (if (member host '("127.0.0.1" "localhost" "0.0.0.0"))
        host
        (begin
          (format (current-error-port)
                  "HOST must be 127.0.0.1, localhost, or 0.0.0.0~%")
          (exit 2)))))

(define (safe-port)
  (let ((port (string->number (environment "PORT" "8080"))))
    (if (and (integer? port) (exact? port) (> port 0) (< port 65536))
        port
        (begin
          (format (current-error-port)
                  "PORT must be between 1 and 65535~%")
          (exit 2)))))

(define (response-headers content-type)
  `((content-type . (,content-type))
    (x-content-type-options . "nosniff")))

(define (respond code content-type body)
  (values
   (build-response
    #:code code
    #:headers (response-headers content-type)
    #:validate-headers? #f)
   body))

(define (read-public-file filename)
  (let* ((public-directory (environment "PUBLIC_DIR" "public"))
         (path (string-append public-directory "/" filename)))
    (catch #t
      (lambda ()
        (call-with-input-file path get-string-all))
      (lambda _
        #f))))

(define (serve-asset path)
  (let ((asset
         (cond
          ((or (string=? path "/") (string=? path "/index.html"))
           '("index.html" text/html))
          ((string=? path "/styles.css")
           '("styles.css" text/css))
          ((string=? path "/app.js")
           '("app.js" text/javascript))
          (else #f))))
    (if (not asset)
        (respond 404 'application/json "{\"error\":\"not found\"}")
        (let ((body (read-public-file (car asset))))
          (if body
              (respond 200 (cadr asset) body)
              (respond
               500
               'application/json
               "{\"error\":\"asset unavailable\"}"))))))

(define (handler request request-body)
  (if (not (eq? (request-method request) 'GET))
      (respond
       405
       'application/json
       "{\"error\":\"method not allowed\"}")
      (let* ((uri (request-uri request))
             (path (uri-path uri))
             (query (uri-query uri)))
        (cond
         ((string=? path "/healthz")
          (respond 200 'text/plain "ok"))
         ((string=? path "/api/simulate")
          (let* ((config (apply-query (default-config) query))
                 (body (json-encode (simulate config))))
            (respond 200 'application/json body)))
         (else
          (serve-asset path))))))

(define (run)
  (let ((host (safe-host))
        (port (safe-port)))
    (format #t
            "{\"event\":\"server.started\",\"url\":\"http://~a:~a\",\"runtime\":\"guile-3\"}~%"
            host port)
    (force-output)
    (run-server handler
                'http
                (list #:host host #:port port))))

(define (main arguments)
  (cond
   ((= (length arguments) 1)
    (run))
   ((and (= (length arguments) 2)
         (string=? (cadr arguments) "--json"))
    (display (json-encode (simulate (default-config))))
    (newline))
   (else
    (format (current-error-port)
            "usage: bloom-filter-saturation-lab [--json]~%")
    (exit 2))))
