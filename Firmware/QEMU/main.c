// main.c - hands off from C startup to the Swift smoke test
//
// Kept to the minimum: everything the test actually does is in App.swift, reached through the
// one `swift_main` entry point.  This exists only because a Cortex-M vector table needs a
// vanilla `main` symbol to call, and because the pass/fail marker and the semihosting exit both
// have to run after Swift returns, not from inside it.

extern void dwt_enable(void);
extern void bump_reset(void);
extern void write0(const char *);
extern void exit_semihosting(int);
extern int swift_main(void);

int main(void) {
    dwt_enable();
    bump_reset();
    write0("booted; entering Swift\n");
    int result = swift_main();
    write0("swift_main returned\n");
    exit_semihosting(result);
    return 0;
}
