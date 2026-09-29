#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif

/*
 * Fixed file-digest verifier (ystack #437).
 *
 * A straight line: check argv and environment, read and frame the
 * instruction on fd 0, validate the path, walk the candidate without
 * following links, classify before opening, read bounded bytes, hash,
 * compare, and write one canonical payload exclusively. See
 * work/fixed-file-digest-verifier/spec.md for the full contract; this
 * file implements it and nothing else. It is inactive: nothing here
 * runs it against a real sandbox, accepts its digest, or grants it
 * authority.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

extern char **environ;

#ifndef YSTACK_SANDBOX_ROOT
#define YSTACK_SANDBOX_ROOT "/sandbox"
#endif

#define CANDIDATE_ROOT YSTACK_SANDBOX_ROOT "/candidate"
#define EVIDENCE_DIR YSTACK_SANDBOX_ROOT "/evidence"
#define EVIDENCE_RESULT_PATH YSTACK_SANDBOX_ROOT "/evidence/file-digest-result.json"
#define TOOLS_DIR YSTACK_SANDBOX_ROOT "/tools"
#define SCRATCH_DIR YSTACK_SANDBOX_ROOT "/scratch"
#define EXPECTED_LANG "LANG=C"
#define EXPECTED_LC_ALL "LC_ALL=C"
#define EXPECTED_PATH "PATH=" TOOLS_DIR
#define EXPECTED_TMPDIR "TMPDIR=" SCRATCH_DIR

#define INSTRUCTION_HEADER "ystack.file-digest-instruction.v1"
#define INSTRUCTION_READ_LIMIT 4209U
#define MAX_PATH_BYTES 4096U
#define MAX_PATH_COMPONENTS 64U
#define MAX_CANDIDATE_BYTES 1048576U
#define CANDIDATE_READ_LIMIT (MAX_CANDIDATE_BYTES + 1U)
#define PAYLOAD_BUFFER_SIZE 20000U

/* R2. Invocation and environment.                                         */

static int argv_ok(int argc, char **argv)
{
    if (argc != 6) return 0;
    if (strcmp(argv[1], "verify") != 0) return 0;
    if (strcmp(argv[2], "--candidate") != 0) return 0;
    if (strcmp(argv[3], CANDIDATE_ROOT) != 0) return 0;
    if (strcmp(argv[4], "--evidence") != 0) return 0;
    if (strcmp(argv[5], EVIDENCE_DIR) != 0) return 0;
    return 1;
}

static int environment_ok(char **envp)
{
    static const char *const expected[4] = {
        EXPECTED_LANG, EXPECTED_LC_ALL, EXPECTED_PATH, EXPECTED_TMPDIR
    };
    int seen[4] = { 0, 0, 0, 0 };
    size_t count = 0;
    char **e;

    for (e = envp; *e != NULL; e++) {
        int i;
        int matched = 0;
        count++;
        for (i = 0; i < 4; i++) {
            if (!seen[i] && strcmp(*e, expected[i]) == 0) {
                seen[i] = 1;
                matched = 1;
                break;
            }
        }
        if (!matched) return 0;
    }
    if (count != 4U) return 0;
    return seen[0] && seen[1] && seen[2] && seen[3];
}

static void refuse_invocation(const char *code)
{
    (void)dprintf(STDERR_FILENO, "%s\n", code);
    exit(64);
}


int main(int argc, char **argv)
{
    if (!argv_ok(argc, argv)) refuse_invocation("E_USAGE");
    if (!environment_ok(environ)) refuse_invocation("E_ENVIRONMENT");
    return 0;
}
