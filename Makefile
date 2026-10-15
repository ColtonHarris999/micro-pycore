# uPyCore: MicroPython bytecode CPU.
#
#   make test          build mpy-cross if needed, verilate, run the hardware suite
#   make test-hw       the hardware suite on its own
#   make regen-goldens  rewrite suite goldens from the unix oracle
#   make run RUN=path  run one MicroPython program
#   make oracle        build the 32-bit unix oracle and smoke it

PYTHON ?= python3
BUILD_PY := upycore/tools/mpy_build.py
MPY_CROSS := build/oracle/src/mpy-cross/build/mpy-cross
RUN ?= upycore/programs/hello.py

DOCKER_IMAGE ?= upycore-sim:local

ORACLE := build/oracle/src/ports/unix/build-upycore/micropython

.PHONY: test sim fw run oracle oracle-header oracle-variant oracle-smoke mpy-cross \
	docker-build docker-test test-hw regen-goldens check-goldens clean

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
	$(PYTHON) upycore/tests/test_hw_manifest.py
	$(PYTHON) $(BUILD_PY) sim
	$(PYTHON) upycore/tools/hw_tests.py
	@if [ -x "$(ORACLE)" ]; then $(PYTHON) upycore/tools/hw_tests.py --check-goldens; fi

test-hw: $(MPY_CROSS)
	$(PYTHON) $(BUILD_PY) sim
	$(PYTHON) upycore/tools/hw_tests.py

regen-goldens:
	variants/upycore/build.sh variant
	$(PYTHON) upycore/tools/hw_tests.py --regen

check-goldens:
	$(PYTHON) upycore/tools/hw_tests.py --check-goldens

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
