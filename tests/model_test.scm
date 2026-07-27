(use-modules (lab model)
             (srfi srfi-1)
             (srfi srfi-64))

(define (strategy response policy)
  (find
   (lambda (item)
     (string=? (assoc-ref item 'policy) policy))
   (assoc-ref response 'strategies)))

(test-begin "bloom-filter-model")

(let* ((response (simulate (default-config)))
       (fixed (strategy response "fixed_definitive"))
       (verify (strategy response "fixed_verify_positive"))
       (scalable (strategy response "scalable_layers"))
       (rotating (strategy response "rotating_generations")))
  (test-equal "four strategies" 4 (length (assoc-ref response 'strategies)))
  (test-assert
   "fixed filter reaches saturation cliff"
   (> (assoc-ref (assoc-ref fixed 'metrics) 'peakEstimatedFppPercent) 30))
  (test-assert
   "scalable layers reduce false positives"
   (< (assoc-ref (assoc-ref scalable 'metrics) 'falsePositives)
      (/ (assoc-ref (assoc-ref fixed 'metrics) 'falsePositives) 10)))
  (test-equal
   "verification preserves valid events"
   0
   (assoc-ref (assoc-ref verify 'metrics) 'lostValidEvents))
  (test-assert
   "verification moves cost to backend"
   (> (assoc-ref (assoc-ref verify 'metrics) 'backendVerifications) 100000))
  (test-assert
   "rotating generations stay bounded"
   (> (assoc-ref (assoc-ref rotating 'metrics) 'rotations) 0)))

(let* ((raw '((candidatesPerSecond . 1)
              (newKeyPercent . 1000)
              (expectedItems . 2)
              (bitsPerItem . 99)
              (hashFunctions . 0)
              (runSeconds . 999)
              (rotateWindowSeconds . 1)
              (layerThresholdPercent . 100)
              (backendP99Ms . 0)
              (seed . 0)))
       (config (normalize-config raw)))
  (test-equal "candidate minimum" 100 (assoc-ref config 'candidatesPerSecond))
  (test-equal "percentage maximum" 99 (assoc-ref config 'newKeyPercent))
  (test-equal "runtime maximum" 300 (assoc-ref config 'runSeconds))
  (test-equal "zero hash count falls back" 5 (assoc-ref config 'hashFunctions))
  (test-equal "zero seed falls back" 28411 (assoc-ref config 'seed)))

(let ((first (json-encode (simulate (default-config))))
      (second (json-encode (simulate (default-config)))))
  (test-equal "same seed is deterministic" first second))

(test-end "bloom-filter-model")
