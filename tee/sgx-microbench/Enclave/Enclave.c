/* Trusted side of the microbenchmark: every ECALL does as little as possible,
 * so that the measured time is the cost of the enclave transition itself, or
 * of the SGX instruction (EREPORT, EGETKEY) it wraps. */
#include <string.h>

#include "Enclave_t.h"
#include "sgx_utils.h"

#define MAX_OCALL_BUF 65536
static uint8_t ocall_buf[MAX_OCALL_BUF];

void ecall_empty(void) {}

void ecall_in(const uint8_t* buf, size_t len) {
    (void)buf;
    (void)len;
}

void ecall_out(uint8_t* buf, size_t len) {
    (void)buf;
    (void)len;
}

void ecall_ocall_loop(uint64_t n) {
    for (uint64_t i = 0; i < n; i++)
        ocall_empty();
}

void ecall_ocall_in_loop(uint64_t n, size_t len) {
    if (len > MAX_OCALL_BUF)
        len = MAX_OCALL_BUF;
    for (uint64_t i = 0; i < n; i++)
        ocall_in(ocall_buf, len);
}

sgx_status_t ecall_self_target_info(sgx_target_info_t* target) {
    return sgx_self_target(target);
}

sgx_status_t ecall_create_report(const sgx_target_info_t* target, const sgx_report_data_t* data,
                                 sgx_report_t* report) {
    return sgx_create_report(target, data, report);
}

sgx_status_t ecall_create_report_loop(uint64_t n, const sgx_target_info_t* target) {
    sgx_report_data_t data;
    sgx_report_t report;
    memset(&data, 0, sizeof(data));
    for (uint64_t i = 0; i < n; i++) {
        memcpy(data.d, &i, sizeof(i));
        sgx_status_t ret = sgx_create_report(target, &data, &report);
        if (ret != SGX_SUCCESS)
            return ret;
    }
    return SGX_SUCCESS;
}

sgx_status_t ecall_verify_report_loop(uint64_t n, const sgx_report_t* report) {
    for (uint64_t i = 0; i < n; i++) {
        sgx_status_t ret = sgx_verify_report(report);
        if (ret != SGX_SUCCESS)
            return ret;
    }
    return SGX_SUCCESS;
}
