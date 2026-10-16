/*
 * Untrusted driver of the SGX microbenchmark.
 *
 * Measures, with the Intel SGX SDK and no LibOS in between:
 *   - the cost of an enclave transition (empty ECALL, empty OCALL),
 *   - the cost of copying buffers across the boundary (ECALL/OCALL with [in] buffers),
 *   - local attestation: sgx_create_report (EREPORT) and sgx_verify_report (EGETKEY + CMAC),
 *   - remote attestation (built WITH_DCAP): DCAP quote generation with the
 *     in-process Quoting Enclave, and quote verification with the DCAP Quote
 *     Verification Library, both cold (collateral fetched from the PCCS/THIM)
 *     and with pre-fetched collateral (pure verification cost).
 *
 * Output is a JSON document in the same format as tee/teebench, consumed by
 * tee/scripts/analyze_tee.py.
 *
 * Usage:
 *   microbench [--samples N] [--slow-samples N] [--out FILE] [--quote-out FILE] [--no-dcap]
 *   microbench verify QUOTE_FILE [--label NAME] [--slow-samples N] [--out FILE]
 */
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "Enclave_u.h"
#include "sgx_urts.h"

#ifdef WITH_DCAP
#include "sgx_dcap_ql_wrapper.h"
#include "sgx_dcap_quoteverify.h"
#endif

#ifndef ENCLAVE_DEBUG
#define ENCLAVE_DEBUG 0
#endif

#define ENCLAVE_FILE "enclave.signed.so"

static sgx_enclave_id_t eid;

/* ---------- timing and results ---------- */

static inline uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

typedef struct {
    char name[64];
    const char* desc;
    int batch;
    double* samples;
    int n;
    char error[128];
    char extra[256]; /* preformatted extra JSON fields, e.g. "\"qv_result\": \"OK\"" */
} result_t;

#define MAX_RESULTS 64
static result_t results[MAX_RESULTS];
static int num_results;

static result_t* new_result(const char* name, const char* desc, int batch, int n) {
    if (num_results == MAX_RESULTS) {
        fprintf(stderr, "too many results\n");
        exit(1);
    }
    result_t* r = &results[num_results++];
    memset(r, 0, sizeof(*r));
    snprintf(r->name, sizeof(r->name), "%s", name);
    r->desc = desc;
    r->batch = batch;
    r->samples = calloc((size_t)n, sizeof(double));
    if (!r->samples) {
        fprintf(stderr, "out of memory\n");
        exit(1);
    }
    return r;
}

static void fail(result_t* r, const char* what, unsigned int code) {
    snprintf(r->error, sizeof(r->error), "%s failed: 0x%04x", what, code);
    r->n = 0;
}

static int cmp_double(const void* a, const void* b) {
    double x = *(const double*)a, y = *(const double*)b;
    return (x > y) - (x < y);
}

static double quantile(const double* sorted, int n, double p) {
    int i = (int)ceil(p * n) - 1;
    if (i < 0)
        i = 0;
    if (i >= n)
        i = n - 1;
    return sorted[i];
}

static void print_summary(const result_t* r) {
    if (r->error[0]) {
        fprintf(stderr, "%-28s error: %s\n", r->name, r->error);
        return;
    }
    double* s = malloc(sizeof(double) * (size_t)r->n);
    memcpy(s, r->samples, sizeof(double) * (size_t)r->n);
    qsort(s, (size_t)r->n, sizeof(double), cmp_double);
    fprintf(stderr, "%-28s p50 %12.3f us  p99 %12.3f us  (n=%d, batch=%d)\n", r->name,
            quantile(s, r->n, 0.5) / 1e3, quantile(s, r->n, 0.99) / 1e3, r->n, r->batch);
    free(s);
}

static void write_stats(FILE* f, const result_t* r) {
    double* s = malloc(sizeof(double) * (size_t)r->n);
    memcpy(s, r->samples, sizeof(double) * (size_t)r->n);
    qsort(s, (size_t)r->n, sizeof(double), cmp_double);
    double sum = 0, sq = 0;
    for (int i = 0; i < r->n; i++)
        sum += s[i];
    double mean = sum / r->n;
    for (int i = 0; i < r->n; i++)
        sq += (s[i] - mean) * (s[i] - mean);
    double stdev = r->n > 1 ? sqrt(sq / (r->n - 1)) : 0;
    fprintf(f,
            "\"stats\": {\"n\": %d, \"mean\": %.3f, \"stdev\": %.3f, \"min\": %.3f, "
            "\"p50\": %.3f, \"p90\": %.3f, \"p95\": %.3f, \"p99\": %.3f, \"max\": %.3f}",
            r->n, mean, stdev, s[0], quantile(s, r->n, 0.5), quantile(s, r->n, 0.9),
            quantile(s, r->n, 0.95), quantile(s, r->n, 0.99), s[r->n - 1]);
    free(s);
}

static int write_json(const char* path, const char* runtime, const char* attestation) {
    FILE* f = strcmp(path, "-") == 0 ? stdout : fopen(path, "w");
    if (!f) {
        fprintf(stderr, "cannot open %s: %s\n", path, strerror(errno));
        return -1;
    }
    fprintf(f, "{\n  \"runtime\": \"%s\",\n  \"attestation\": \"%s\",\n  \"start\": %ld,\n  \"results\": [\n",
            runtime, attestation, (long)time(NULL));
    for (int i = 0; i < num_results; i++) {
        const result_t* r = &results[i];
        fprintf(f, "    {\"name\": \"%s\", \"desc\": \"%s\", \"batch\": %d, \"unit\": \"ns/op\"", r->name,
                r->desc, r->batch);
        if (r->extra[0])
            fprintf(f, ", %s", r->extra);
        if (r->error[0] || r->n == 0) {
            fprintf(f, ", \"error\": \"%s\"}", r->error[0] ? r->error : "no samples");
        } else {
            fprintf(f, ", ");
            write_stats(f, r);
            fprintf(f, ", \"samples\": [");
            for (int j = 0; j < r->n; j++)
                fprintf(f, "%s%.1f", j ? ", " : "", r->samples[j]);
            fprintf(f, "]}");
        }
        fprintf(f, "%s\n", i + 1 < num_results ? "," : "");
    }
    fprintf(f, "  ]\n}\n");
    if (f != stdout)
        fclose(f);
    return 0;
}

/* ---------- OCALLs ---------- */

void ocall_empty(void) {}

void ocall_in(const uint8_t* buf, size_t len) {
    (void)buf;
    (void)len;
}

/* ---------- enclave transition benchmarks ---------- */

static void bench_timer(int n) {
    result_t* r = new_result("timer", "clock_gettime(CLOCK_MONOTONIC) overhead included in per-op samples", 1000, n);
    for (int i = 0; i < n; i++) {
        uint64_t t0 = now_ns();
        for (int j = 0; j < 1000; j++)
            (void)now_ns();
        r->samples[i] = (double)(now_ns() - t0) / 1000;
    }
    r->n = n;
}

static void bench_ecall_empty(int n, int warmup) {
    result_t* r = new_result("ecall_empty", "empty ECALL round trip (EENTER + EEXIT)", 1, n);
    for (int i = 0; i < warmup + n; i++) {
        uint64_t t0 = now_ns();
        sgx_status_t ret = ecall_empty(eid);
        uint64_t t1 = now_ns();
        if (ret != SGX_SUCCESS)
            { fail(r, "ecall_empty", ret); return; }
        if (i >= warmup)
            r->samples[i - warmup] = (double)(t1 - t0);
    }
    r->n = n;
}

static void bench_ecall_in(int n, int warmup, size_t len) {
    char name[64];
    snprintf(name, sizeof(name), "ecall_in_%zuB", len);
    result_t* r = new_result(name, "ECALL with an [in] buffer copied into the enclave", 1, n);
    uint8_t* buf = calloc(1, len);
    for (int i = 0; i < warmup + n; i++) {
        uint64_t t0 = now_ns();
        sgx_status_t ret = ecall_in(eid, buf, len);
        uint64_t t1 = now_ns();
        if (ret != SGX_SUCCESS) {
            free(buf);
            { fail(r, "ecall_in", ret); return; }
        }
        if (i >= warmup)
            r->samples[i - warmup] = (double)(t1 - t0);
    }
    r->n = n;
    free(buf);
}

static void bench_ecall_out(int n, int warmup, size_t len) {
    char name[64];
    snprintf(name, sizeof(name), "ecall_out_%zuB", len);
    result_t* r = new_result(name, "ECALL with an [out] buffer copied out of the enclave", 1, n);
    uint8_t* buf = calloc(1, len);
    for (int i = 0; i < warmup + n; i++) {
        uint64_t t0 = now_ns();
        sgx_status_t ret = ecall_out(eid, buf, len);
        uint64_t t1 = now_ns();
        if (ret != SGX_SUCCESS) {
            free(buf);
            { fail(r, "ecall_out", ret); return; }
        }
        if (i >= warmup)
            r->samples[i - warmup] = (double)(t1 - t0);
    }
    r->n = n;
    free(buf);
}

/* OCALLs are issued in a loop from one ECALL; the ECALL cost is amortized over the batch. */
static void bench_ocall(int n, int warmup, int batch, size_t len) {
    char name[64];
    if (len == 0)
        snprintf(name, sizeof(name), "ocall_empty");
    else
        snprintf(name, sizeof(name), "ocall_in_%zuB", len);
    result_t* r = new_result(name,
                             len == 0 ? "empty OCALL round trip (EEXIT + EENTER), batched inside one ECALL"
                                      : "OCALL with an [in] buffer copied out of the enclave, batched",
                             batch, n);
    for (int i = 0; i < warmup + n; i++) {
        uint64_t t0 = now_ns();
        sgx_status_t ret = len == 0 ? ecall_ocall_loop(eid, (uint64_t)batch)
                                    : ecall_ocall_in_loop(eid, (uint64_t)batch, len);
        uint64_t t1 = now_ns();
        if (ret != SGX_SUCCESS)
            { fail(r, "ecall_ocall_loop", ret); return; }
        if (i >= warmup)
            r->samples[i - warmup] = (double)(t1 - t0) / batch;
    }
    r->n = n;
}

/* ---------- local attestation ---------- */

static void bench_reports(int n, int warmup, int batch) {
    sgx_target_info_t self;
    sgx_status_t ecall_ret, ret;

    result_t* r = new_result("report_create", "sgx_create_report (EREPORT), batched inside one ECALL", batch, n);
    ecall_ret = ecall_self_target_info(eid, &ret, &self);
    if (ecall_ret != SGX_SUCCESS || ret != SGX_SUCCESS)
        { fail(r, "sgx_self_target", ecall_ret != SGX_SUCCESS ? ecall_ret : ret); return; }
    for (int i = 0; i < warmup + n; i++) {
        uint64_t t0 = now_ns();
        ecall_ret = ecall_create_report_loop(eid, &ret, (uint64_t)batch, &self);
        uint64_t t1 = now_ns();
        if (ecall_ret != SGX_SUCCESS || ret != SGX_SUCCESS)
            { fail(r, "sgx_create_report", ecall_ret != SGX_SUCCESS ? ecall_ret : ret); return; }
        if (i >= warmup)
            r->samples[i - warmup] = (double)(t1 - t0) / batch;
    }
    r->n = n;

    r = new_result("report_create_ecall", "one ECALL that creates one report (what an application pays per report)",
                   1, n);
    sgx_report_data_t data;
    sgx_report_t report;
    memset(&data, 0, sizeof(data));
    for (int i = 0; i < warmup + n; i++) {
        memcpy(data.d, &i, sizeof(i));
        uint64_t t0 = now_ns();
        ecall_ret = ecall_create_report(eid, &ret, &self, &data, &report);
        uint64_t t1 = now_ns();
        if (ecall_ret != SGX_SUCCESS || ret != SGX_SUCCESS)
            { fail(r, "sgx_create_report", ecall_ret != SGX_SUCCESS ? ecall_ret : ret); return; }
        if (i >= warmup)
            r->samples[i - warmup] = (double)(t1 - t0);
    }
    r->n = n;

    r = new_result("report_verify", "sgx_verify_report (EGETKEY + CMAC), batched inside one ECALL", batch, n);
    for (int i = 0; i < warmup + n; i++) {
        uint64_t t0 = now_ns();
        ecall_ret = ecall_verify_report_loop(eid, &ret, (uint64_t)batch, &report);
        uint64_t t1 = now_ns();
        if (ecall_ret != SGX_SUCCESS || ret != SGX_SUCCESS)
            { fail(r, "sgx_verify_report", ecall_ret != SGX_SUCCESS ? ecall_ret : ret); return; }
        if (i >= warmup)
            r->samples[i - warmup] = (double)(t1 - t0) / batch;
    }
    r->n = n;
}

/* ---------- remote attestation (DCAP) ---------- */

#ifdef WITH_DCAP
static const char* qv_result_str(sgx_ql_qv_result_t res) {
    switch (res) {
    case SGX_QL_QV_RESULT_OK: return "OK";
    case SGX_QL_QV_RESULT_CONFIG_NEEDED: return "CONFIG_NEEDED";
    case SGX_QL_QV_RESULT_OUT_OF_DATE: return "OUT_OF_DATE";
    case SGX_QL_QV_RESULT_OUT_OF_DATE_CONFIG_NEEDED: return "OUT_OF_DATE_CONFIG_NEEDED";
    case SGX_QL_QV_RESULT_SW_HARDENING_NEEDED: return "SW_HARDENING_NEEDED";
    case SGX_QL_QV_RESULT_CONFIG_AND_SW_HARDENING_NEEDED: return "CONFIG_AND_SW_HARDENING_NEEDED";
    case SGX_QL_QV_RESULT_INVALID_SIGNATURE: return "INVALID_SIGNATURE";
    case SGX_QL_QV_RESULT_REVOKED: return "REVOKED";
    case SGX_QL_QV_RESULT_UNSPECIFIED: return "UNSPECIFIED";
    default: return "OTHER";
    }
}

/* A verification "succeeds" for timing purposes if the quote signature chain
 * was checked; TCB-level statuses (OUT_OF_DATE, SW_HARDENING_NEEDED, ...) are
 * policy results that depend on the platform patch level, and are recorded. */
static int qv_terminal(sgx_ql_qv_result_t res) {
    return res == SGX_QL_QV_RESULT_INVALID_SIGNATURE || res == SGX_QL_QV_RESULT_REVOKED ||
           res == SGX_QL_QV_RESULT_UNSPECIFIED;
}

static int verify_once(const uint8_t* quote, uint32_t size, const sgx_ql_qve_collateral_t* collateral,
                       uint8_t* supp, uint32_t supp_size, sgx_ql_qv_result_t* qv_res, quote3_error_t* err) {
    uint32_t expiration = 1;
    *err = sgx_qv_verify_quote(quote, size, collateral, time(NULL), &expiration, qv_res, NULL, supp_size, supp);
    return *err == SGX_QL_SUCCESS && !qv_terminal(*qv_res) ? 0 : -1;
}

static void bench_verify(const char* label, const uint8_t* quote, uint32_t size, int n) {
    char name[64];
    uint32_t supp_size = 0;
    uint8_t* supp = NULL;
    sgx_ql_qv_result_t qv_res = SGX_QL_QV_RESULT_UNSPECIFIED;
    quote3_error_t err;

    if (sgx_qv_get_quote_supplemental_data_size(&supp_size) == SGX_QL_SUCCESS && supp_size > 0)
        supp = malloc(supp_size);

    /* First verification: fetches the verification collateral (TCB info, QE identity,
     * CRLs) from the PCCS/THIM through the Quote Provider Library. */
    snprintf(name, sizeof(name), "%squote_verify_first", label);
    result_t* r = new_result(name, "first DCAP quote verification, including the collateral fetch", 1, 1);
    uint64_t t0 = now_ns();
    int rc = verify_once(quote, size, NULL, supp, supp_size, &qv_res, &err);
    uint64_t t1 = now_ns();
    snprintf(r->extra, sizeof(r->extra), "\"qv_result\": \"%s\", \"quote_size\": %u", qv_result_str(qv_res), size);
    if (rc != 0) {
        fail(r, "sgx_qv_verify_quote", err != SGX_QL_SUCCESS ? (unsigned)err : (unsigned)qv_res);
        free(supp);
        return;
    }
    r->samples[0] = (double)(t1 - t0);
    r->n = 1;

    /* Repeated verification without collateral: the QPL serves the collateral from its cache. */
    snprintf(name, sizeof(name), "%squote_verify", label);
    r = new_result(name, "DCAP quote verification, collateral served from the QPL cache", 1, n);
    snprintf(r->extra, sizeof(r->extra), "\"qv_result\": \"%s\"", qv_result_str(qv_res));
    for (int i = 0; i < n; i++) {
        t0 = now_ns();
        rc = verify_once(quote, size, NULL, supp, supp_size, &qv_res, &err);
        t1 = now_ns();
        if (rc != 0) {
            fail(r, "sgx_qv_verify_quote", err != SGX_QL_SUCCESS ? (unsigned)err : (unsigned)qv_res);
            free(supp);
            return;
        }
        r->samples[i] = (double)(t1 - t0);
    }
    r->n = n;

    /* Collateral fetch on its own, and verification with pre-fetched collateral
     * (the pure cryptographic cost of checking a quote). */
    uint8_t* collateral = NULL;
    uint32_t collateral_size = 0;
    snprintf(name, sizeof(name), "%scollateral_fetch", label);
    r = new_result(name, "tee_qv_get_collateral (QPL, served from cache after the first fetch)", 1, n);
    for (int i = 0; i < n; i++) {
        if (collateral)
            tee_qv_free_collateral(collateral);
        collateral = NULL;
        t0 = now_ns();
        err = tee_qv_get_collateral(quote, size, &collateral, &collateral_size);
        t1 = now_ns();
        if (err != SGX_QL_SUCCESS) {
            fail(r, "tee_qv_get_collateral", err);
            free(supp);
            return;
        }
        r->samples[i] = (double)(t1 - t0);
    }
    r->n = n;

    snprintf(name, sizeof(name), "%squote_verify_collateral", label);
    r = new_result(name, "DCAP quote verification with pre-fetched collateral (no QPL/network)", 1, n);
    for (int i = 0; i < n; i++) {
        t0 = now_ns();
        rc = verify_once(quote, size, (const sgx_ql_qve_collateral_t*)collateral, supp, supp_size, &qv_res, &err);
        t1 = now_ns();
        if (rc != 0) {
            fail(r, "sgx_qv_verify_quote", err != SGX_QL_SUCCESS ? (unsigned)err : (unsigned)qv_res);
            break;
        }
        r->samples[i] = (double)(t1 - t0);
        r->n = i + 1;
    }
    tee_qv_free_collateral(collateral);
    free(supp);
}

static int bench_quote(int n, const char* quote_out) {
    sgx_target_info_t qe_target;
    sgx_report_data_t data;
    sgx_report_t report;
    sgx_status_t ecall_ret, ret;
    uint32_t size = 0;
    quote3_error_t err;

    sgx_qe_set_enclave_load_policy(SGX_QL_PERSISTENT);

    result_t* r = new_result("quote_target_info_first", "sgx_qe_get_target_info, first call (loads the QE)", 1, 1);
    uint64_t t0 = now_ns();
    err = sgx_qe_get_target_info(&qe_target);
    uint64_t t1 = now_ns();
    if (err != SGX_QL_SUCCESS) {
        fail(r, "sgx_qe_get_target_info", err);
        return -1;
    }
    r->samples[0] = (double)(t1 - t0);
    r->n = 1;

    if ((err = sgx_qe_get_quote_size(&size)) != SGX_QL_SUCCESS) {
        fail(r, "sgx_qe_get_quote_size", err);
        return -1;
    }
    uint8_t* quote = malloc(size);
    memset(&data, 0, sizeof(data));

    /* Quote generation = report targeted at the QE (one ECALL) + QE signs it. */
    result_t* first = new_result("quote_generate_first", "first DCAP quote, including the PCK certificate fetch", 1, 1);
    r = new_result("quote_generate", "DCAP quote generation: ECALL report for the QE + sgx_qe_get_quote", 1, n);
    for (int i = 0; i <= n; i++) {
        memcpy(data.d, &i, sizeof(i));
        t0 = now_ns();
        ecall_ret = ecall_create_report(eid, &ret, &qe_target, &data, &report);
        if (ecall_ret != SGX_SUCCESS || ret != SGX_SUCCESS) {
            fail(i ? r : first, "sgx_create_report", ecall_ret != SGX_SUCCESS ? ecall_ret : ret);
            free(quote);
            return -1;
        }
        err = sgx_qe_get_quote(&report, size, quote);
        t1 = now_ns();
        if (err != SGX_QL_SUCCESS) {
            fail(i ? r : first, "sgx_qe_get_quote", err);
            free(quote);
            return -1;
        }
        if (i == 0) {
            first->samples[0] = (double)(t1 - t0);
            first->n = 1;
        } else {
            r->samples[i - 1] = (double)(t1 - t0);
        }
    }
    r->n = n;
    snprintf(r->extra, sizeof(r->extra), "\"quote_size\": %u", size);

    if (quote_out) {
        FILE* f = fopen(quote_out, "wb");
        if (f) {
            fwrite(quote, 1, size, f);
            fclose(f);
        }
    }
    bench_verify("", quote, size, n);
    free(quote);
    return 0;
}

static int verify_file(const char* path, const char* label, int n) {
    FILE* f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "cannot open %s: %s\n", path, strerror(errno));
        return -1;
    }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t* quote = malloc((size_t)size);
    if (fread(quote, 1, (size_t)size, f) != (size_t)size) {
        fclose(f);
        free(quote);
        return -1;
    }
    fclose(f);
    char prefix[64];
    snprintf(prefix, sizeof(prefix), "%s_", label);
    bench_verify(prefix, quote, (uint32_t)size, n);
    free(quote);
    return 0;
}
#endif /* WITH_DCAP */

/* ---------- main ---------- */

static void usage(void) {
    fprintf(stderr,
            "usage: microbench [--samples N] [--slow-samples N] [--warmup N] [--out FILE] [--quote-out FILE] [--no-dcap]\n"
            "       microbench verify QUOTE_FILE [--label NAME] [--slow-samples N] [--out FILE]\n");
    exit(2);
}

int main(int argc, char** argv) {
    int samples = 10000, slow_samples = 300, warmup = 1000, batch = 1000, dcap = 1;
    const char *out = "-", *quote_out = NULL, *verify_path = NULL, *label = "external";

    int i = 1;
    if (argc > 1 && strcmp(argv[1], "verify") == 0) {
        if (argc < 3)
            usage();
        verify_path = argv[2];
        i = 3;
    }
    for (; i < argc; i++) {
        if (!strcmp(argv[i], "--samples") && i + 1 < argc)
            samples = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--slow-samples") && i + 1 < argc)
            slow_samples = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--warmup") && i + 1 < argc)
            warmup = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--out") && i + 1 < argc)
            out = argv[++i];
        else if (!strcmp(argv[i], "--quote-out") && i + 1 < argc)
            quote_out = argv[++i];
        else if (!strcmp(argv[i], "--label") && i + 1 < argc)
            label = argv[++i];
        else if (!strcmp(argv[i], "--no-dcap"))
            dcap = 0;
        else
            usage();
    }

#ifdef WITH_DCAP
    const char* attestation = dcap ? "sgx-sdk-dcap" : "none";
#else
    const char* attestation = "none";
    (void)dcap;
    (void)quote_out;
    (void)label;
    (void)slow_samples;
#endif

    if (verify_path) {
#ifdef WITH_DCAP
        if (verify_file(verify_path, label, slow_samples) != 0)
            return 1;
        for (int k = 0; k < num_results; k++)
            print_summary(&results[k]);
        return write_json(out, "sgx-sdk-verify", attestation) == 0 ? 0 : 1;
#else
        fprintf(stderr, "built without DCAP support\n");
        return 1;
#endif
    }

    sgx_status_t ret = sgx_create_enclave(ENCLAVE_FILE, ENCLAVE_DEBUG, NULL, NULL, &eid, NULL);
    if (ret != SGX_SUCCESS) {
        fprintf(stderr, "sgx_create_enclave failed: 0x%04x\n", ret);
        return 1;
    }

    bench_timer(samples / 10);
    bench_ecall_empty(samples, warmup);
    bench_ecall_in(samples, warmup, 64);
    bench_ecall_in(samples, warmup, 4096);
    bench_ecall_out(samples, warmup, 4096);
    bench_ocall(samples / 10, warmup / 10, batch, 0);
    bench_ocall(samples / 10, warmup / 10, batch, 64);
    bench_ocall(samples / 10, warmup / 10, batch, 4096);
    bench_reports(samples / 10, warmup / 10, batch);
#ifdef WITH_DCAP
    if (dcap)
        bench_quote(slow_samples, quote_out);
#endif

    for (int k = 0; k < num_results; k++)
        print_summary(&results[k]);
    int rc = write_json(out, SGX_MODE_NAME, attestation);
    sgx_destroy_enclave(eid);
    return rc == 0 ? 0 : 1;
}
