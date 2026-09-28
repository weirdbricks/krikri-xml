abs_spec_bin := justfile_directory() + "/.crystal-build-cache/spec_bin"

# Run the spec suite in parallel across 4 real OS threads.
#
# minitest.cr's --parallel needs Crystal's multi-thread scheduler
# (-Dpreview_mt) to actually use more than one core - without it,
# --parallel just interleaves fibers on one thread and buys nothing.
# 4 threads is the measured sweet spot: the suite's wall time is bounded
# by the largest single test (~2.6s entity-expansion boundary test), so
# more threads add overhead without shortening the critical path.
test: build-spec
    CRYSTAL_WORKERS=4 {{abs_spec_bin}} --parallel 4

# Single-threaded run (no -Dpreview_mt) - use this to bisect whether a
# failure is a real bug or a parallel-run race.
test-serial:
    crystal spec

build-spec:
    mkdir -p .crystal-build-cache
    crystal build -Dpreview_mt spec/spec_helper.cr spec/*_spec.cr -o {{abs_spec_bin}}
