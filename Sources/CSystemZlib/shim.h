/* shim.h - exposes the system zlib to Swift
 *
 * The engine can reach DEFLATE either through the Swift implementation in the
 * LZ77 module or through this one.  The C library defaults to zlib because that
 * is what the reference build links against, which keeps compressed output and
 * the tuning knobs (level, strategy, window bits, memory level) behaving
 * identically for clients that depend on them.
 */

#include <zlib.h>
