FROM python:3.14-slim

ENV DEBIAN_FRONTEND=noninteractive

# Verilator 5.032 (Debian trixie) builds the uPyCore hart. Ubuntu's 5.020
# rejects slices of function-call return values used in the RTL.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential git make verilator \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work

CMD ["make", "test"]
