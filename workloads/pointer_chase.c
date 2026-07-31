#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static uint64_t rng_state = UINT64_C(0x9e3779b97f4a7c15);

static uint64_t next_random(void) {
    uint64_t x = rng_state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    rng_state = x;
    return x * UINT64_C(2685821657736338717);
}

static double seconds_now(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        perror("clock_gettime");
        exit(2);
    }
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static uint64_t parse_positive(const char *text, const char *name) {
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value == 0) {
        fprintf(stderr, "invalid %s: %s\n", name, text);
        exit(2);
    }
    return (uint64_t)value;
}

int main(int argc, char **argv) {
    const uint64_t size_mib = argc > 1 ? parse_positive(argv[1], "size_mib") : 512;
    const uint64_t accesses_million = argc > 2 ? parse_positive(argv[2], "accesses_million") : 20;
    const uint64_t max_size_mib =
        ((uint64_t)UINT32_MAX * sizeof(uint32_t)) / (UINT64_C(1024) * UINT64_C(1024));
    if (argc > 3 || size_mib > max_size_mib ||
        accesses_million > UINT64_MAX / UINT64_C(1000000)) {
        fprintf(stderr, "usage: %s [size_mib<=%" PRIu64 "] [accesses_million]\n",
                argv[0], max_size_mib);
        return 2;
    }
    const uint64_t bytes = size_mib * UINT64_C(1024) * UINT64_C(1024);
    const uint64_t count = bytes / sizeof(uint32_t);
    const uint64_t accesses = accesses_million * UINT64_C(1000000);

    if (count < 2 || count > UINT32_MAX) {
        fprintf(stderr, "usage: %s [size_mib] [accesses_million]\n", argv[0]);
        fprintf(stderr, "size must contain 2..%" PRIu32 " uint32_t entries\n", UINT32_MAX);
        return 2;
    }

    uint32_t *next = NULL;
    int alloc_rc = posix_memalign((void **)&next, 4096, (size_t)bytes);
    if (alloc_rc != 0) {
        fprintf(stderr, "posix_memalign(%" PRIu64 " MiB): error %d\n", size_mib, alloc_rc);
        return 2;
    }

    for (uint64_t i = 0; i < count; ++i) {
        next[i] = (uint32_t)i;
    }

    /* Sattolo shuffle: the array itself becomes one fixed-seed random cycle. */
    for (uint64_t i = count - 1; i > 0; --i) {
        uint64_t j = next_random() % i;
        uint32_t tmp = next[i];
        next[i] = next[j];
        next[j] = tmp;
    }

    uint32_t index = 0;
    uint64_t warmup = accesses < UINT64_C(1000000) ? accesses : UINT64_C(1000000);
    for (uint64_t i = 0; i < warmup; ++i) {
        index = next[index];
    }

    double start = seconds_now();
    for (uint64_t i = 0; i < accesses; ++i) {
        index = next[index];
    }
    double elapsed = seconds_now() - start;

    printf("working_set_mib %" PRIu64 "\n", size_mib);
    printf("accesses %" PRIu64 "\n", accesses);
    printf("pointer_chase_ns_per_access %.3f ns\n", elapsed * 1e9 / (double)accesses);
    printf("checksum %" PRIu32 "\n", index);
    free(next);
    return 0;
}
