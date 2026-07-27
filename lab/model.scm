(define-module (lab model)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (default-config
            normalize-config
            apply-query
            simulate
            json-encode))

(define strategy-count 4)

(define (default-config)
  '((candidatesPerSecond . 8000)
    (newKeyPercent . 82)
    (expectedItems . 250000)
    (bitsPerItem . 8)
    (hashFunctions . 5)
    (runSeconds . 120)
    (rotateWindowSeconds . 30)
    (layerThresholdPercent . 70)
    (backendP99Ms . 14)
    (seed . 28411)))

(define (config-ref config key)
  (assoc-ref config key))

(define (clamp value minimum maximum)
  (min maximum (max minimum value)))

(define (positive-or-default value fallback)
  (if (and (number? value) (integer? value) (> value 0))
      value
      fallback))

(define (normalize-config input)
  (let ((defaults (default-config)))
    `((candidatesPerSecond
       . ,(clamp
           (positive-or-default
            (assoc-ref input 'candidatesPerSecond)
            (config-ref defaults 'candidatesPerSecond))
           100 100000))
      (newKeyPercent
       . ,(clamp
           (positive-or-default
            (assoc-ref input 'newKeyPercent)
            (config-ref defaults 'newKeyPercent))
           10 99))
      (expectedItems
       . ,(clamp
           (positive-or-default
            (assoc-ref input 'expectedItems)
            (config-ref defaults 'expectedItems))
           10000 5000000))
      (bitsPerItem
       . ,(clamp
           (positive-or-default
            (assoc-ref input 'bitsPerItem)
            (config-ref defaults 'bitsPerItem))
           2 24))
      (hashFunctions
       . ,(clamp
           (positive-or-default
            (assoc-ref input 'hashFunctions)
            (config-ref defaults 'hashFunctions))
           1 12))
      (runSeconds
       . ,(clamp
           (positive-or-default
            (assoc-ref input 'runSeconds)
            (config-ref defaults 'runSeconds))
           20 300))
      (rotateWindowSeconds
       . ,(clamp
           (positive-or-default
            (assoc-ref input 'rotateWindowSeconds)
            (config-ref defaults 'rotateWindowSeconds))
           10 120))
      (layerThresholdPercent
       . ,(clamp
           (positive-or-default
            (assoc-ref input 'layerThresholdPercent)
            (config-ref defaults 'layerThresholdPercent))
           40 90))
      (backendP99Ms
       . ,(clamp
           (positive-or-default
            (assoc-ref input 'backendP99Ms)
            (config-ref defaults 'backendP99Ms))
           1 500))
      (seed
       . ,(clamp
           (positive-or-default
            (assoc-ref input 'seed)
            (config-ref defaults 'seed))
           1 2147483647)))))

(define query-keys
  '(("candidates_per_second" . candidatesPerSecond)
    ("new_key_percent" . newKeyPercent)
    ("expected_items" . expectedItems)
    ("bits_per_item" . bitsPerItem)
    ("hash_functions" . hashFunctions)
    ("run_seconds" . runSeconds)
    ("rotate_window_seconds" . rotateWindowSeconds)
    ("layer_threshold_percent" . layerThresholdPercent)
    ("backend_p99_ms" . backendP99Ms)
    ("seed" . seed)))

(define (parse-positive-integer value)
  (let ((parsed (and value (string->number value))))
    (and (integer? parsed) (exact? parsed) (>= parsed 0) parsed)))

(define (split-on text character)
  (let loop ((start 0) (index 0) (parts '()))
    (cond
     ((= index (string-length text))
      (reverse (cons (substring text start index) parts)))
     ((char=? (string-ref text index) character)
      (loop (+ index 1) (+ index 1)
            (cons (substring text start index) parts)))
     (else
      (loop start (+ index 1) parts)))))

(define (query-pairs query)
  (if (or (not query) (string-null? query))
      '()
      (filter-map
       (lambda (part)
         (let ((pieces (split-on part #\=)))
           (and (= (length pieces) 2)
                (cons (car pieces) (cadr pieces)))))
       (split-on query #\&))))

(define (apply-query config query)
  (normalize-config
   (fold
    (lambda (pair result)
      (let* ((mapping (assoc (car pair) query-keys))
             (parsed (parse-positive-integer (cdr pair))))
        (if (and mapping parsed)
            (acons (cdr mapping)
                   parsed
                   (alist-delete (cdr mapping) result))
            result)))
    config
    (query-pairs query))))

(define (round-to value places)
  (let ((factor (expt 10 places)))
    (/ (round (* value factor)) factor)))

(define (bloom-fill hashes entries bits)
  (if (<= bits 0)
      1.0
      (- 1.0 (exp (/ (* -1.0 hashes entries) bits)))))

(define (bloom-fpp fill hashes)
  (expt (max 0.0 (min 1.0 fill)) hashes))

(define (combine-fpp fills hashes)
  (- 1.0
     (fold
      (lambda (fill product)
        (* product (- 1.0 (bloom-fpp fill hashes))))
      1.0
      fills)))

(define (make-rng seed)
  (vector seed))

(define (random-next! state)
  (let* ((current (vector-ref state 0))
         (next (modulo (+ (* current 1664525) 1013904223)
                       4294967296)))
    (vector-set! state 0 next)
    next))

(define (jitter! state)
  (+ 0.97 (/ (modulo (random-next! state) 61) 1000.0)))

(define strategy-definitions
  '((fixed
     (policy . "fixed_definitive")
     (name . "Fixed + definitive")
     (kicker . "one bitset · no second opinion")
     (description
      . "Treat every maybe-present answer as truth, even after the filter exceeds its planned cardinality.")
     (tradeoff
      . "Fast and bounded, but valid unseen keys disappear as false positives accelerate.")
     (color . "#ef476f")
     (recommended . #f))
    (verify
     (policy . "fixed_verify_positive")
     (name . "Verify positives")
     (kicker . "same bitset · authoritative read")
     (description
      . "Check every maybe-present result against the source of truth before rejecting a candidate.")
     (tradeoff
      . "Preserves correctness, but saturation converts the filter from a shortcut into backend traffic.")
     (color . "#7259d6")
     (recommended . #f))
    (scalable
     (policy . "scalable_layers")
     (name . "Scalable layers")
     (kicker . "grow early · query every layer")
     (description
      . "Open a larger layer when the active filter reaches its configured capacity threshold.")
     (tradeoff
      . "Keeps error bounded while memory and multi-layer lookup work grow with cardinality.")
     (color . "#087e8b")
     (recommended . #t))
    (rotating
     (policy . "rotating_generations")
     (name . "Rotating generations")
     (kicker . "bounded window · two generations")
     (description
      . "Rotate two half-window filters so expired membership ages out with the business dedupe window.")
     (tradeoff
      . "Bounded and cheap only when forgetting keys after the configured TTL is semantically correct.")
     (color . "#ff9f1c")
     (recommended . #f))))

(define (definition kind key)
  (let ((entry (assoc kind strategy-definitions)))
    (assoc-ref (cdr entry) key)))

(define (initial-layer expected bits-per-item)
  `((entries . 0.0)
    (capacity . ,(* 1.0 expected))
    (bits . ,(* 1.0 expected bits-per-item))))

(define (replace-last items value)
  (reverse (cons value (cdr (reverse items)))))

(define (layer-fill layer hashes)
  (bloom-fill hashes
              (assoc-ref layer 'entries)
              (assoc-ref layer 'bits)))

(define (layer-with-entries layer entries)
  (acons 'entries entries (alist-delete 'entries layer)))

(define (sum-key items key)
  (fold (lambda (item total) (+ total (assoc-ref item key))) 0.0 items))

(define (timeline-sample? second run-seconds)
  (or (= second 0)
      (= second (- run-seconds 1))
      (= (modulo (+ second 1) (max 1 (quotient run-seconds 48))) 0)))

(define (trace-sample? second run-seconds)
  (let ((spacing (max 1 (quotient run-seconds 7))))
    (or (= second 0)
        (= second (- run-seconds 1))
        (= (modulo (+ second 1) spacing) 0))))

(define (simulate-strategy config kind seed-offset)
  (let* ((seconds (config-ref config 'runSeconds))
         (candidate-rate (* 1.0 (config-ref config 'candidatesPerSecond)))
         (new-rate (* candidate-rate
                      (/ (config-ref config 'newKeyPercent) 100.0)))
         (duplicate-rate (- candidate-rate new-rate))
         (expected (* 1.0 (config-ref config 'expectedItems)))
         (bits-per-item (* 1.0 (config-ref config 'bitsPerItem)))
         (hashes (config-ref config 'hashFunctions))
         (threshold (/ (config-ref config 'layerThresholdPercent) 100.0))
         (window (config-ref config 'rotateWindowSeconds))
         (half-window (max 1 (quotient window 2)))
         (base-bits (* expected bits-per-item))
         (rng (make-rng (+ (config-ref config 'seed) seed-offset))))
    (let loop ((second 0)
               (entries 0.0)
               (layers (list (initial-layer expected bits-per-item)))
               (generation-a 0.0)
               (generation-b 0.0)
               (active-generation 0)
               (rotations 0)
               (cumulative-fp 0)
               (cumulative-lost 0)
               (cumulative-verifications 0)
               (peak-fpp 0.0)
               (peak-fill 0.0)
               (guardrail-breaches 0)
               (timeline '())
               (events '()))
      (if (= second seconds)
          (let* ((final-point (car timeline))
                 (memory-bits
                  (case kind
                    ((scalable) (sum-key layers 'bits))
                    ((rotating) base-bits)
                    (else base-bits)))
                 (metrics
                  `((candidates . ,(* (config-ref config 'candidatesPerSecond)
                                      seconds))
                    (newKeys . ,(inexact->exact (round (* new-rate seconds))))
                    (memoryMiB . ,(round-to (/ memory-bits 8.0 1024.0 1024.0) 2))
                    (finalFillPercent . ,(assoc-ref final-point 'fillPercent))
                    (peakFillPercent . ,(round-to (* peak-fill 100.0) 2))
                    (finalEstimatedFppPercent
                     . ,(assoc-ref final-point 'estimatedFppPercent))
                    (peakEstimatedFppPercent . ,(round-to (* peak-fpp 100.0) 3))
                    (falsePositives . ,cumulative-fp)
                    (lostValidEvents . ,cumulative-lost)
                    (backendVerifications . ,cumulative-verifications)
                    (duplicateHits
                     . ,(inexact->exact (round (* duplicate-rate seconds))))
                    (layers . ,(if (eq? kind 'scalable) (length layers) 1))
                    (rotations . ,rotations)
                    (guardrailBreaches . ,guardrail-breaches)
                    (decisionP99Ms
                     . ,(round-to
                         (case kind
                           ((verify)
                            (+ (config-ref config 'backendP99Ms)
                               (* peak-fill 0.8)))
                           ((scalable) (* 0.07 (length layers)))
                           ((rotating) 0.16)
                           (else (+ 0.06 (* peak-fill 0.12))))
                         2)))))
            `((policy . ,(definition kind 'policy))
              (name . ,(definition kind 'name))
              (kicker . ,(definition kind 'kicker))
              (description . ,(definition kind 'description))
              (tradeoff . ,(definition kind 'tradeoff))
              (color . ,(definition kind 'color))
              (recommended . ,(definition kind 'recommended))
              (metrics . ,metrics)
              (timeline . ,(reverse timeline))
              (events . ,(reverse events))))
          (let* ((rotating-now?
                  (and (eq? kind 'rotating)
                       (> second 0)
                       (= (modulo second half-window) 0)))
                 (next-active
                  (if rotating-now? (- 1 active-generation) active-generation))
                 (next-rotations (if rotating-now? (+ rotations 1) rotations))
                 (reset-a
                  (if (and rotating-now? (= next-active 0)) 0.0 generation-a))
                 (reset-b
                  (if (and rotating-now? (= next-active 1)) 0.0 generation-b))
                 (grown-layers
                  (if (and (eq? kind 'scalable)
                           (>= (/ (assoc-ref (last layers) 'entries)
                                  (assoc-ref (last layers) 'capacity))
                               threshold))
                      (append
                       layers
                       (list
                        (initial-layer
                         (* (assoc-ref (last layers) 'capacity) 2.0)
                         bits-per-item)))
                      layers))
                 (fixed-fill (bloom-fill hashes entries base-bits))
                 (layer-fills (map (lambda (layer) (layer-fill layer hashes))
                                   grown-layers))
                 (rotating-fills
                  (list
                   (bloom-fill hashes reset-a (/ base-bits 2.0))
                   (bloom-fill hashes reset-b (/ base-bits 2.0))))
                 (estimated-fpp
                  (case kind
                    ((scalable) (combine-fpp layer-fills hashes))
                    ((rotating) (combine-fpp rotating-fills hashes))
                    (else (bloom-fpp fixed-fill hashes))))
                 (observed-fp
                  (inexact->exact
                   (round (* new-rate estimated-fpp (jitter! rng)))))
                 (accepted-new
                  (if (or (eq? kind 'verify))
                      new-rate
                      (max 0.0 (- new-rate observed-fp))))
                 (next-entries (+ entries accepted-new))
                 (next-layers
                  (if (eq? kind 'scalable)
                      (let* ((active (last grown-layers))
                             (updated
                              (layer-with-entries
                               active
                               (+ (assoc-ref active 'entries) accepted-new))))
                        (replace-last grown-layers updated))
                      grown-layers))
                 (next-a
                  (if (and (eq? kind 'rotating) (= next-active 0))
                      (+ reset-a accepted-new)
                      reset-a))
                 (next-b
                  (if (and (eq? kind 'rotating) (= next-active 1))
                      (+ reset-b accepted-new)
                      reset-b))
                 (fill
                  (case kind
                    ((scalable) (apply max (map (lambda (layer)
                                                 (layer-fill layer hashes))
                                               next-layers)))
                    ((rotating)
                     (max (bloom-fill hashes next-a (/ base-bits 2.0))
                          (bloom-fill hashes next-b (/ base-bits 2.0))))
                    (else (bloom-fill hashes next-entries base-bits))))
                 (lost (if (eq? kind 'verify) 0 observed-fp))
                 (verifications
                  (if (eq? kind 'verify)
                      (+ (inexact->exact (round duplicate-rate)) observed-fp)
                      0))
                 (next-cumulative-fp (+ cumulative-fp observed-fp))
                 (next-cumulative-lost (+ cumulative-lost lost))
                 (next-cumulative-verifications
                  (+ cumulative-verifications verifications))
                 (memory-bits
                  (case kind
                    ((scalable) (sum-key next-layers 'bits))
                    ((rotating) base-bits)
                    (else base-bits)))
                 (point
                  `((second . ,(+ second 1))
                    (fillPercent . ,(round-to (* fill 100.0) 2))
                    (estimatedFppPercent . ,(round-to (* estimated-fpp 100.0) 3))
                    (observedFalsePositives . ,observed-fp)
                    (cumulativeFalsePositives . ,next-cumulative-fp)
                    (lostValidEvents . ,next-cumulative-lost)
                    (backendVerifications . ,next-cumulative-verifications)
                    (memoryMiB . ,(round-to (/ memory-bits 8.0 1024.0 1024.0) 2))
                    (layers . ,(if (eq? kind 'scalable)
                                   (length next-layers)
                                   1))
                    (rotations . ,next-rotations)))
                 (event
                  `((timestampMs . ,(* (+ second 1) 1000))
                    (generation . ,(if (eq? kind 'rotating)
                                       next-active
                                       0))
                    (layer . ,(if (eq? kind 'scalable)
                                  (- (length next-layers) 1)
                                  0))
                    (bitFillPercent . ,(assoc-ref point 'fillPercent))
                    (estimatedFppPercent
                     . ,(assoc-ref point 'estimatedFppPercent))
                    (candidateClass . "new-key")
                    (filterDecision
                     . ,(if (> observed-fp 0)
                            "maybe-present"
                            "definitely-absent"))
                    (authority
                     . ,(if (eq? kind 'verify)
                            "source-of-truth"
                            "bloom-filter"))
                    (outcome
                     . ,(cond
                        ((and (eq? kind 'verify) (> observed-fp 0))
                         "false-positive-recovered")
                        ((> observed-fp 0) "valid-event-dropped")
                        (else "valid-event-accepted")))
                    (verificationMs
                     . ,(if (eq? kind 'verify)
                            (config-ref config 'backendP99Ms)
                            0)))))
            (loop (+ second 1)
                  next-entries
                  next-layers
                  next-a
                  next-b
                  next-active
                  next-rotations
                  next-cumulative-fp
                  next-cumulative-lost
                  next-cumulative-verifications
                  (max peak-fpp estimated-fpp)
                  (max peak-fill fill)
                  (+ guardrail-breaches (if (> estimated-fpp 0.01) 1 0))
                  (if (timeline-sample? second seconds)
                      (cons point timeline)
                      timeline)
                  (if (trace-sample? second seconds)
                      (cons event events)
                      events)))))))

(define (simulate raw-config)
  (let ((config (normalize-config raw-config)))
    `((config . ,config)
      (strategies
       . ,(map
           (lambda (entry index)
             (simulate-strategy config (car entry) (* index 100003)))
           strategy-definitions
           (iota strategy-count))))))

(define (json-object? value)
  (and (pair? value)
       (every
        (lambda (entry)
          (and (pair? entry)
               (or (symbol? (car entry)) (string? (car entry)))))
        value)))

(define (json-escape value)
  (call-with-output-string
   (lambda (port)
     (string-for-each
      (lambda (character)
        (case character
          ((#\") (display "\\\"" port))
          ((#\\) (display "\\\\" port))
          ((#\newline) (display "\\n" port))
          ((#\return) (display "\\r" port))
          ((#\tab) (display "\\t" port))
          (else (write-char character port))))
      value))))

(define (json-write value port)
  (cond
   ((string? value)
    (format port "\"~a\"" (json-escape value)))
   ((symbol? value)
    (format port "\"~a\"" (json-escape (symbol->string value))))
   ((boolean? value)
    (display (if value "true" "false") port))
   ((number? value)
    (display value port))
   ((json-object? value)
    (display "{" port)
    (let loop ((entries value) (first? #t))
      (unless (null? entries)
        (unless first? (display "," port))
        (json-write (car (car entries)) port)
        (display ":" port)
        (json-write (cdr (car entries)) port)
        (loop (cdr entries) #f)))
    (display "}" port))
   ((list? value)
    (display "[" port)
    (let loop ((items value) (first? #t))
      (unless (null? items)
        (unless first? (display "," port))
        (json-write (car items) port)
        (loop (cdr items) #f)))
    (display "]" port))
   (else
    (error "unsupported JSON value" value))))

(define (json-encode value)
  (call-with-output-string
   (lambda (port)
     (json-write value port))))
