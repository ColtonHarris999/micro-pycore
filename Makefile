# uPyCore: MicroPython bytecode CPU.
#
#   make test          build mpy-cross if needed, verilate, run hello and raise
#   make run RUN=path  run one MicroPython program
#   make oracle        build the 32-bit unix oracle and smoke it

PYTHON ?= python3
BUILD_PY := upycore/tools/mpy_build.py
MPY_CROSS := build/oracle/src/mpy-cross/build/mpy-cross
RUN ?= upycore/programs/hello.py

DOCKER_IMAGE ?= upycore-sim:local

.PHONY: test sim fw run oracle oracle-header oracle-variant oracle-smoke mpy-cross \
	docker-build docker-test clean

$(MPY_CROSS):
	variants/upycore/build.sh mpy-cross

mpy-cross: $(MPY_CROSS)

sim:
	$(PYTHON) $(BUILD_PY) sim

fw: $(MPY_CROSS)
	$(PYTHON) $(BUILD_PY) fw

run: $(MPY_CROSS)
	$(PYTHON) $(BUILD_PY) run $(RUN)

test: $(MPY_CROSS)
	$(PYTHON) upycore/tests/test_mpy_periph_model.py
	$(PYTHON) $(BUILD_PY) sim
	@mkdir -p build/mpy/check
	$(PYTHON) $(BUILD_PY) run upycore/programs/hello.py > build/mpy/check/hello.stdout
	printf 'hello\n' | cmp -s - build/mpy/check/hello.stdout
	@set +e; \
	$(PYTHON) $(BUILD_PY) run upycore/programs/raise.py > build/mpy/check/raise.stdout 2> build/mpy/check/raise.stderr; \
	rc=$$?; \
	set -e; \
	test "$$rc" = 1; \
	grep -q "ValueError: nope" build/mpy/check/raise.stderr; \
	test ! -s build/mpy/check/raise.stdout

oracle-header:
	variants/upycore/build.sh header

oracle-variant:
	variants/upycore/build.sh variant

oracle-smoke:
	variants/upycore/build.sh smoke

oracle: oracle-header oracle-smoke

docker-build:
	docker build -t $(DOCKER_IMAGE) .

docker-test: docker-build
	docker run --rm -v "$(CURDIR):/work" -w /work $(DOCKER_IMAGE) make test

clean:
	rm -rf build/mpy build/mpy_soc
