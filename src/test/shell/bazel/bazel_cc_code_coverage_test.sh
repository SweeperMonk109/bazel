#!/bin/bash -eu
#
# Copyright 2018 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Unit tests for tools/test/collect_cc_code_coverage.sh

# Load the test setup defined in the parent directory
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CURRENT_DIR}/../integration_test_setup.sh" \
  || { echo "integration_test_setup.sh not found!" >&2; exit 1; }

# Check if all the tools required by CC coverage are installed.
[[ ! -x /usr/bin/lcov ]] && echo "lcov not installed. Skipping test" && exit 0
[[ -z $( which gcov ) ]] && fail "gcov not installed. Skipping test" && exit 0
[[ -z $( which g++ ) ]] && fail "g++ not installed. Skipping test" && exit 0

# These are the variables needed by tools/test/collect_cc_coverage.sh
# They will be properly sub-shelled when invoking the script.

# Directory containing gcno and gcda files.
readonly COVERAGE_DIR_VAR="${PWD}/coverage_dir"
# Location of gcov.
readonly COVERAGE_GCOV_PATH_VAR="${PWD}/mygcov"
# Location from where the code coverage collection was invoked.
readonly ROOT_VAR="${PWD}"
# Location of the instrumented file manifest.
readonly COVERAGE_MANIFEST_VAR="${PWD}/coverage_manifest.txt"
# Location of the final coverage report.
readonly COVERAGE_OUTPUT_FILE_VAR="${PWD}/coverage_report.dat"

# Path to the canonical C++ coverage script.
readonly COLLECT_CC_COVERAGE_SCRIPT=tools/test/collect_cc_coverage.sh

# Return a string in the form "device_id%inode" for a given file.
#
# Checking if two files have the same deviceID and inode is enough to
# determine if they are the same. For more details about inodes see
# http://www.grymoire.com/Unix/Inodes.html.
#
# - file   The absolute path of the file.
function get_file_id() {
  local file="${1}"
  stat -c "%d:%i" ${file}
}

# Setup to be run for every test.
function set_up() {
   mkdir -p "${COVERAGE_DIR_VAR}"

  # COVERAGE_DIR has to be different than ROOT and PWD for the test to be
  # accurate.
  local coverage_dir_id=$(get_file_id "$COVERAGE_DIR_VAR")
  [[ $coverage_dir_id == $(get_file_id "$ROOT_VAR") ]] \
      && fail "COVERAGE_DIR_VAR must be different than ROOT_VAR"
  [[ $coverage_dir_id == $(get_file_id "$PWD") ]] \
      && fail "COVERAGE_DIR_VAR must be different than PWD"

  # The script expects gcov to be at $COVERAGE_GCOV_PATH.
  cp $( which gcov ) "$COVERAGE_GCOV_PATH_VAR"

  # The script expects the output file to already exist.
  # TODO(iirina): In the future it would be better if the
  # script creates the output file.
  touch "$COVERAGE_OUTPUT_FILE_VAR"

  # All generated .gcno files need to be in the manifest otherwise
  # the coverage report will be incomplete.
  echo "coverage_srcs/t.gcno" >> "$COVERAGE_MANIFEST_VAR"
  echo "coverage_srcs/a.gcno" >> "$COVERAGE_MANIFEST_VAR"

  # Create the CC sources.
  mkdir -p coverage_srcs/
  cat << EOF > coverage_srcs/a.h
int a(bool what);
EOF

  cat << EOF > coverage_srcs/a.cc
#include "a.h"

int a(bool what) {
  if (what) {
    return 1;
  } else {
    return 2;
  }
}
EOF

  cat << EOF > coverage_srcs/t.cc
#include <stdio.h>
#include "a.h"

int main(void) {
  a(true);
}
EOF

  generate_and_execute_instrumented_binary coverage_srcs/test \
      "$COVERAGE_DIR_VAR/coverage_srcs" \
      coverage_srcs/a.h coverage_srcs/a.cc coverage_srcs/t.cc

   # g++ generates the notes files in the current directory. The documentation
   # (https://gcc.gnu.org/onlinedocs/gcc/Gcov-Data-Files.html#Gcov-Data-Files)
   # says they are placed in the same directory as the object file, but they
   # are not. Therefore we move them in the same directory.
   mv a.gcno coverage_srcs/a.gcno
   mv t.gcno coverage_srcs/t.gcno
}

# Generates and executes an instrumented binary:
#
# Reads the list of arguments provided by the caller (using $@) and uses them
# to produce an instrumented binary using g++. This step also generates
# the notes (.gcno) files.
#
# Executes the instrumented binary. This step also generates the
# profile data (.gcda) files.
# - path_to_binary destination of the binary produced by g++
function generate_and_execute_instrumented_binary() {
  local path_to_binary="${1}"; shift
  local gcda_directory="${1}"; shift
  # -fprofile-arcs   Instruments $path_to_binary. During execution the binary
  #                  records code coverage information.
  # -ftest-coverage  Produces a notes (.gcno) file that coverage utilities
  #                  (e.g. gcov, lcov) can use to show a coverage report.
  # -fprofile-dir    Sets the directory where the profile data (gcda) appears.
  #
  # The profile data files need to be at a specific location where the C++
  # coverage scripts expects them to be ($COVERAGE_DIR/path/to/sources/).
  g++ -fprofile-arcs -ftest-coverage \
      -fprofile-dir="$gcda_directory" \
      "$@" -o "$path_to_binary"  \
       || fail "Couldn't produce the instrumented binary for $@ \
            with path_to_binary $path_to_binary"

   # Execute the instrumented binary and generates the profile data (.gcda)
   # file.
   # The profile data file is placed in $gcda_directory.
  "$path_to_binary" || fail "Couldn't execute the instrumented binary \
      $path_to_binary"
}

function tear_down() {
  rm -f "$COVERAGE_MANIFEST_VAR"
  rm -f "$COVERAGE_GCOV_PATH_VAR"
  rm -f "$COVERAGE_OUTPUT_FILE_VAR"
  rm -rf "$COVERAGE_DIR_VAR"
  rm -rf coverage_srcs/
}

# Runs the script that computes the code coverage report for CC code.
# Sets up the sub-shell environment accordingly:
# - COVERAGE_DIR            Directory containing gcda files.
# - COVERAGE_MANIFEST       Location of the instrumented file manifest.
# - COVERAGE_OUTPUT_FILE    Location of the final coverage report.
# - COVERAGE_GCOV_PATH      Location of gcov.
# - ROOT                    Location from where the code coverage collection
#                           was invoked.
function run_coverage() {
  (COVERAGE_DIR="$COVERAGE_DIR_VAR" \
   COVERAGE_GCOV_PATH="$COVERAGE_GCOV_PATH_VAR" \
   ROOT="$ROOT_VAR" COVERAGE_MANIFEST="$COVERAGE_MANIFEST_VAR" \
   COVERAGE_OUTPUT_FILE="$COVERAGE_OUTPUT_FILE_VAR" \
   "$COLLECT_CC_COVERAGE_SCRIPT")
}

function test_cc_test_coverage() {
    # Run the C++ coverage script with the environment setup accordingly.
    # This will get coverage results for coverage_srcs/a.cc and
    # coverage_srcs/t.cc.
    run_coverage > "$TEST_log"

    # Assert that the C++ coverage output is correct.
    # The covered files are coverage_srcs/a.cc and coverage_srcs/t.cc.
    # The expected total number of lines of COVERAGE_OUTPUT_FILE
    # is 25. This number can be computed by counting the number
    # of lines in the variables declared below $expected_result_a_cc
    # and $expected_result_t_cc.
    [[ $(wc -l < "$COVERAGE_OUTPUT_FILE_VAR") == 25 ]] || \
        fail "Number of lines $nr_of_lines is different than 25"

    # The expected result can be constructed manually by following the lcov
    # documentation and manually checking what lines of code are covered when
    # running the test.
    # For details about the lcov format see
    # http://ltp.sourceforge.net/coverage/lcov/geninfo.1.php
    # The newlines are replaced with commas to facilitate comparing the
    # expected values with the actual results.

    # The expected coverage result for coverage_srcs/a.cc.
    local expected_result_a_cc="TN:,\
SF:coverage_srcs/a.cc,\
FN:3,_Z1ab,\
FNDA:1,_Z1ab,\
FNF:1,\
FNH:1,\
DA:3,1,\
DA:4,1,\
DA:5,1,\
DA:7,0,\
LF:4,\
LH:3,\
end_of_record"

    # The expected coverage result for coverage_srcs/t.cc.
    local expected_result_t_cc="TN:,\
SF:coverage_srcs/t.cc,\
FN:4,main,\
FNDA:1,main,\
FNF:1,\
FNH:1,\
DA:4,1,\
DA:5,1,\
DA:6,1,\
LF:3,\
LH:3,\
end_of_record"

    # Assert that the coverage output file contains the coverage data for the
    # two cc files: coverage_srcs/a.cc and coverage_srcs/t.cc.
    # The C++ coverage script places the final coverage result in
    # $COVERAGE_OUTPUT_FILE.
    #
    # The result for each source file must be asserted separately because the
    # coverage tools (e.g. lcov, gcov) do not guarantee any particular order.
    # The order can differ for example based on OS or version. The source files
    # order in the coverage report is not relevant.
    tr '\n' , < "$COVERAGE_OUTPUT_FILE_VAR" | grep "$expected_result_a_cc" \
        || fail "Wrong coverage results for coverage_srcs/a.cc"
    tr '\n' , < "$COVERAGE_OUTPUT_FILE_VAR" | grep "$expected_result_t_cc" \
        || fail "Wrong coverage results for coverage_srcs/t.cc"
}
