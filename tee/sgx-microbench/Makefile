# SGX microbenchmark (Intel SGX SDK + DCAP).
#
#   make                      # hardware enclave, with DCAP quote generation/verification
#   make SGX_MODE=SIM         # simulation mode (no SGX needed, no DCAP), for testing
#   make WITH_DCAP=0          # hardware enclave without DCAP
#
# Run from this directory: ./microbench --out results.json

SGX_SDK ?= /opt/intel/sgxsdk
SGX_MODE ?= HW
WITH_DCAP ?= $(if $(filter HW,$(SGX_MODE)),1,0)

SGX_LIBRARY_PATH := $(SGX_SDK)/lib64
SGX_EDGER8R := $(SGX_SDK)/bin/x64/sgx_edger8r
SGX_SIGNER := $(SGX_SDK)/bin/x64/sgx_sign

ifeq ($(SGX_MODE), HW)
	TRTS_LIB := sgx_trts
	SERVICE_LIB := sgx_tservice
	URTS_LIB := sgx_urts
	MODE_NAME := sgx-sdk-hw
	DISABLE_DEBUG := 1
	ENCLAVE_DEBUG := 0
else
	TRTS_LIB := sgx_trts_sim
	SERVICE_LIB := sgx_tservice_sim
	URTS_LIB := sgx_urts_sim
	MODE_NAME := sgx-sdk-sim
	DISABLE_DEBUG := 0
	ENCLAVE_DEBUG := 1
endif

APP_CFLAGS := -O2 -fPIC -Wall -Wextra -I$(SGX_SDK)/include -IApp \
	-DENCLAVE_DEBUG=$(ENCLAVE_DEBUG) -DSGX_MODE_NAME=\"$(MODE_NAME)\"
APP_LDFLAGS := -L$(SGX_LIBRARY_PATH) -l$(URTS_LIB) -lpthread -lm
ifeq ($(WITH_DCAP), 1)
	APP_CFLAGS += -DWITH_DCAP
	APP_LDFLAGS += -lsgx_dcap_ql -lsgx_dcap_quoteverify
endif

ENCLAVE_CFLAGS := -O2 -Wall -nostdinc -fvisibility=hidden -fpie -ffunction-sections -fdata-sections \
	-fstack-protector-strong -I$(SGX_SDK)/include -I$(SGX_SDK)/include/tlibc -IEnclave
ENCLAVE_LDFLAGS := -Wl,--no-undefined -nostdlib -nodefaultlibs -nostartfiles -L$(SGX_LIBRARY_PATH) \
	-Wl,--whole-archive -l$(TRTS_LIB) -Wl,--no-whole-archive \
	-Wl,--start-group -lsgx_tstdc -lsgx_tcrypto -l$(SERVICE_LIB) -Wl,--end-group \
	-Wl,-Bstatic -Wl,-Bsymbolic -Wl,--no-undefined \
	-Wl,-pie,-eenclave_entry -Wl,--export-dynamic \
	-Wl,--defsym,__ImageBase=0 -Wl,--gc-sections \
	-Wl,--version-script=Enclave/Enclave.lds

.PHONY: all clean

all: microbench enclave.signed.so

App/Enclave_u.c App/Enclave_u.h: Enclave/Enclave.edl
	cd App && $(SGX_EDGER8R) --untrusted ../Enclave/Enclave.edl --search-path ../Enclave --search-path $(SGX_SDK)/include

Enclave/Enclave_t.c Enclave/Enclave_t.h: Enclave/Enclave.edl
	cd Enclave && $(SGX_EDGER8R) --trusted Enclave.edl --search-path . --search-path $(SGX_SDK)/include

microbench: App/App.c App/Enclave_u.c App/Enclave_u.h
	$(CC) $(APP_CFLAGS) App/App.c App/Enclave_u.c -o $@ $(APP_LDFLAGS)

enclave.so: Enclave/Enclave.c Enclave/Enclave_t.c Enclave/Enclave_t.h
	$(CC) $(ENCLAVE_CFLAGS) Enclave/Enclave.c Enclave/Enclave_t.c -o $@ $(ENCLAVE_LDFLAGS)

Enclave/Enclave.config.xml: Enclave/Enclave.config.xml.in
	sed 's/@DISABLE_DEBUG@/$(DISABLE_DEBUG)/' $< > $@

Enclave/private.pem:
	openssl genrsa -out $@ -3 3072

enclave.signed.so: enclave.so Enclave/Enclave.config.xml Enclave/private.pem
	$(SGX_SIGNER) sign -key Enclave/private.pem -enclave enclave.so -out $@ -config Enclave/Enclave.config.xml

clean:
	rm -f microbench enclave.so enclave.signed.so App/Enclave_u.* Enclave/Enclave_t.* Enclave/Enclave.config.xml
