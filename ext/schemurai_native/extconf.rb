# frozen_string_literal: true

require "mkmf"

# Platform gems resolve Ruby symbols from the running interpreter so the same
# binary also works with Rubies built without a shared libruby.
$LIBRUBYARG = "" unless enable_config("link-ruby", true) # rubocop:disable Style/GlobalVars -- mkmf build configuration.

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
          ID identity = rb_intern_const("compare_by_identity");
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
end
$LOCAL_LIBS << " $(srcdir)/target/release/libschemurai_native.a" # rubocop:disable Style/GlobalVars -- mkmf build configuration.
$LOCAL_LIBS << " -lpthread -ldl -lm" unless /mswin|mingw/ =~ RUBY_PLATFORM # rubocop:disable Style/GlobalVars -- mkmf build configuration.
create_makefile("schemurai_native")
File.open("Makefile", "a") do |file|
  file.puts <<~MAKE

    $(TARGET_SO): $(srcdir)/target/release/libschemurai_native.a

    glue.o: $(srcdir)/protocol.h $(srcdir)/protocol.def

    $(srcdir)/target/release/libschemurai_native.a: $(srcdir)/Cargo.toml $(srcdir)/Cargo.lock $(srcdir)/build.rs $(srcdir)/protocol.def $(wildcard $(srcdir)/src/*.rs $(srcdir)/src/*/*.rs)
    \tcargo build --manifest-path $(srcdir)/Cargo.toml --release --locked
  MAKE
end
