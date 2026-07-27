GUILE ?= guile
GUILD ?= guild
NODE ?= node

.PHONY: all compile test check run clean docker-check

all: check

compile: clean
	mkdir -p build/lab
	$(GUILD) compile -L . -o build/lab/model.go lab/model.scm
	$(GUILD) compile -L . -o build/lab/server.go lab/server.scm

test:
	GUILE_AUTO_COMPILE=0 $(GUILE) -L . tests/model_test.scm
	sh tests/server_test.sh
	./bloom-filter-saturation-lab --json | jq -e '.strategies | length == 4' >/dev/null

check: compile test
	$(NODE) --check public/app.js

run:
	GUILE_AUTO_COMPILE=0 ./bloom-filter-saturation-lab

clean:
	rm -rf build bloom-filter-model.log

docker-check:
	docker build -t bloom-filter-saturation-lab:test .
	container_id="$$(docker run -d -p 127.0.0.1::8080 bloom-filter-saturation-lab:test)"; \
	trap 'docker rm -f "$$container_id" >/dev/null 2>&1 || true' EXIT INT TERM; \
	host_port="$$(docker port "$$container_id" 8080/tcp | sed 's/.*://')"; \
	attempt=0; \
	until curl -fsS "http://127.0.0.1:$$host_port/healthz" >/dev/null; do \
	  attempt=$$((attempt + 1)); \
	  test "$$attempt" -lt 50; \
	  sleep 0.25; \
	done; \
	test "$$(docker exec "$$container_id" id -u)" = "10001"; \
	curl -fsS "http://127.0.0.1:$$host_port/api/simulate" | \
	  jq -e '.strategies | length == 4' >/dev/null
