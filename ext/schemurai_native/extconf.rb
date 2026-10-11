# frozen_string_literal: true

require "mkmf"

unless find_executable("cargo")
  warn "cargo was not found; skipping the optional native backend (Ruby and VM remain available)"
  File.write("Makefile", dummy_makefile(".").join)
  exit
end
unless enable_config("portable-hash-walk", false)
  if have_func("rb_hash_stlike_foreach", ["ruby.h", "ruby/st.h"])
    # CRuby 3.4/4.0 identity Hashes always use ST storage. Check the private
    # storage flag against a fresh interpreter before enabling the read hint.
    ar_proof = !CROSS_COMPILING && try_run(<<~C)
      #include <ruby.h>
      #include <ruby/version.h>
      #if (RUBY_API_VERSION_MAJOR == 3 && RUBY_API_VERSION_MINOR == 4) || \
          (RUBY_API_VERSION_MAJOR == 4 && RUBY_API_VERSION_MINOR == 0)
      int main(int argc, char **argv) {
          ruby_sysinit(&argc, &argv);
          RUBY_INIT_STACK;
          ruby_init();
          int status = 0;
          ID identity = rb_intern("compare_by_identity");
          for (int n = 0; n <= 8; n++) {
              VALUE h = rb_hash_new();
              VALUE id = rb_funcall(rb_hash_new(), identity, 0);
              for (int i = 0; i < n; i++) {
                  rb_hash_aset(h, INT2FIX(i), INT2FIX(i));
                  rb_hash_aset(id, INT2FIX(i), INT2FIX(i));
              }
              VALUE hashes[] = {h, rb_obj_freeze(rb_hash_dup(h)),
                  rb_funcall(rb_hash_dup(h), identity, 0), id};
              for (int i = 0; i < 4; i++) {
                  int st = RB_FL_TEST_RAW(hashes[i], RUBY_FL_USER3) != 0;
                  if (st != (i >= 2)) status = 1;
              }
              RB_GC_GUARD(h);
              RB_GC_GUARD(id);
          }
          return ruby_cleanup(status);
      }
      #else
      int main(void) { return 1; }
      #endif
    C
    $defs << "-DSCHEMURAI_AR_HASH_PROOF" if ar_proof # rubocop:disable Style/GlobalVars -- mkmf build configuration.
  end
  big_sample_proof = !CROSS_COMPILING && try_run(<<~C)
    #include "big_sample.h"
    #if SN_BIG_SAMPLE_LAYOUT_SUPPORTED
    static int check(VALUE value) {
        if (!RB_TYPE_P(value, T_BIGNUM)) return 1;
        uint32_t low;
        int sign = rb_integer_pack(value, &low, 1, sizeof(low), 0,
            INTEGER_PACK_LSWORD_FIRST | INTEGER_PACK_NATIVE_BYTE_ORDER);
        uint64_t expected = (uint64_t)low | ((uint64_t)(sign < 0) << 32);
        return sn_checked_big_sample(value) != expected;
    }
    int main(int argc, char **argv) {
        ruby_sysinit(&argc, &argv);
        RUBY_INIT_STACK;
        ruby_init();
        int status = 0, embedded = 0, heap = 0;
        uint64_t words[513];
        uint64_t lows[] = {0, 1, UINT32_MAX, UINT64_C(1) << 32, UINT64_MAX};
        for (int bits = 0; bits <= 32768; bits += bits < 256 ? 1 : 256) {
            for (int at = 0; at < 5; at++) {
                for (int negative = 0; negative < 2; negative++) {
                    memset(words, 0, sizeof(words));
                    words[bits / 64] = UINT64_C(1) << (bits % 64);
                    words[0] = lows[at];
                    int flags = INTEGER_PACK_LSWORD_FIRST | INTEGER_PACK_NATIVE_BYTE_ORDER |
                        INTEGER_PACK_FORCE_BIGNUM | (negative ? INTEGER_PACK_NEGATIVE : 0);
                    VALUE value = rb_integer_unpack(words, bits / 64 + 1, sizeof(uint64_t), 0, flags);
                    if (RB_FL_TEST_RAW(value, RUBY_FL_USER2)) embedded = 1;
                    else heap = 1;
                    status |= check(value);
                    rb_obj_freeze(value);
                    status |= check(value);
                    if (at == 0 && (bits == 0 || bits == 192 || bits == 32768)) {
                        rb_gc_start();
                        status |= check(value);
                    }
                    RB_GC_GUARD(value);
                }
            }
        }
        return ruby_cleanup(status || !embedded || !heap);
    }
    #else
    int main(void) { return 1; }
    #endif
  C
  $defs << "-DSCHEMURAI_BIG_SAMPLE_PROOF" if big_sample_proof # rubocop:disable Style/GlobalVars -- mkmf build configuration.
end
$LOCAL_LIBS << " $(srcdir)/target/release/libschemurai_native.a" # rubocop:disable Style/GlobalVars -- mkmf build configuration.
$LOCAL_LIBS << " -lpthread -ldl -lm" unless /mswin|mingw/ =~ RUBY_PLATFORM # rubocop:disable Style/GlobalVars -- mkmf build configuration.
create_makefile("schemurai_native")
File.open("Makefile", "a") do |file|
  file.puts <<~MAKE

    $(TARGET_SO): $(srcdir)/target/release/libschemurai_native.a

    glue.o: $(srcdir)/big_sample.h

    $(srcdir)/target/release/libschemurai_native.a: $(srcdir)/Cargo.toml $(srcdir)/Cargo.lock $(wildcard $(srcdir)/src/*.rs)
    \tcargo build --manifest-path $(srcdir)/Cargo.toml --release --locked
  MAKE
end
