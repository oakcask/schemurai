#ifndef SCHEMURAI_BIG_SAMPLE_H
#define SCHEMURAI_BIG_SAMPLE_H
#include <ruby.h>
#include <ruby/version.h>
#include <stdint.h>
#include <string.h>

/* Version-limited CRuby representation hint, enabled only after a build probe
 * compares it with public packing. No private structure is cast or mutated. */
#if SIZEOF_VOIDP == 8 && SIZEOF_INT == 4 && SIZEOF_LONG_LONG >= 8 && \
    ((RUBY_API_VERSION_MAJOR == 3 && RUBY_API_VERSION_MINOR == 4) || \
     (RUBY_API_VERSION_MAJOR == 4 && RUBY_API_VERSION_MINOR == 0))
#define SN_BIG_SAMPLE_LAYOUT_SUPPORTED 1
static inline uint64_t sn_checked_big_sample(VALUE value) {
    VALUE flags = RBASIC(value)->flags;
    size_t len;
    const uint32_t *digits;
    const char *body = (const char *)value + sizeof(struct RBasic);
    if (flags & RUBY_FL_USER2) {
        size_t mask = RUBY_API_VERSION_MAJOR == 3 ? 7 : 511;
        len = (flags / RUBY_FL_USER3) & mask;
        digits = (const uint32_t *)body;
    } else {
        memcpy(&len, body, sizeof(len));
        memcpy(&digits, body + sizeof(len), sizeof(digits));
    }
    uint32_t low = len ? digits[0] : 0;
    int negative = !(flags & RUBY_FL_USER1);
    /* Public packing normalizes signed zero, including forced Big objects. */
    if (negative && low == 0) {
        while (len && digits[len - 1] == 0) len--;
        negative = len != 0;
    }
    return (uint64_t)low | ((uint64_t)negative << 32);
}
#else
#define SN_BIG_SAMPLE_LAYOUT_SUPPORTED 0
#endif
#endif
