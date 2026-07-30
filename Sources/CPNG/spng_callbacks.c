/* spng_callbacks.c - registering client callbacks, and calling them
 *
 * Every transfer of control into client code goes through a trampoline here.
 * Collecting them in one place is what makes the jump discipline checkable: a
 * client may longjmp out of any of these, so a call site must have committed
 * anything it still needs to the context before calling, and must hold nothing
 * that needs releasing.
 *
 * The registration functions are here rather than in Swift because they only
 * write plain fields of the control structure, and keeping them next to the
 * trampolines that read those fields keeps the pairing obvious.
 */

#include "spng_internal.h"

#include <stdio.h>

/* -- registration --------------------------------------------------------- */

void PNGAPI
png_set_error_fn(png_structrp png_ptr, png_voidp error_ptr,
    png_error_ptr error_fn, png_error_ptr warning_fn)
{
   if (png_ptr == NULL)
      return;

   png_ptr->error_ptr = error_ptr;
   png_ptr->error_fn = error_fn;
   png_ptr->warning_fn = warning_fn;
}

png_voidp PNGAPI
png_get_error_ptr(png_const_structrp png_ptr)
{
   if (png_ptr == NULL)
      return NULL;

   return png_ptr->error_ptr;
}

void PNGAPI
png_set_benign_errors(png_structrp png_ptr, int allowed)
{
   png_uint_32 bit;

   if (png_ptr == NULL)
      return;

   /* Reading and writing are tracked separately: tolerating a damaged file you
    * are reading is reasonable, tolerating a mistake in a file you are producing
    * usually is not.
    */
   bit = (png_ptr->flags & SPNG_FLAG_IS_READ) != 0
       ? SPNG_FLAG_BENIGN_READ_ERR : SPNG_FLAG_BENIGN_WRITE_ERR;

   if (allowed)
      png_ptr->flags |= bit;

   else
      png_ptr->flags &= ~bit;
}

void PNGAPI
png_set_read_fn(png_structrp png_ptr, png_voidp io_ptr, png_rw_ptr read_data_fn)
{
   if (png_ptr == NULL)
      return;

   png_ptr->io_ptr = io_ptr;
   png_ptr->read_fn = read_data_fn != NULL ? read_data_fn : spng_c_stdio_read;

   /* A structure reads or writes, never both, so installing one direction clears
    * the other rather than leaving a callback that could be reached by mistake.
    */
   png_ptr->write_fn = NULL;
   png_ptr->output_flush_fn = NULL;
}

void PNGAPI
png_set_write_fn(png_structrp png_ptr, png_voidp io_ptr, png_rw_ptr write_data_fn,
    png_flush_ptr output_flush_fn)
{
   if (png_ptr == NULL)
      return;

   png_ptr->io_ptr = io_ptr;
   png_ptr->write_fn = write_data_fn != NULL ? write_data_fn : spng_c_stdio_write;
   png_ptr->output_flush_fn = output_flush_fn;
   png_ptr->read_fn = NULL;
}

void PNGAPI
png_init_io(png_structrp png_ptr, png_FILE_p fp)
{
   if (png_ptr == NULL)
      return;

   png_ptr->io_ptr = (png_voidp)fp;

   /* Which direction to wire up is decided by what the structure was created
    * for, since png_init_io does not say.
    */
   if ((png_ptr->flags & SPNG_FLAG_IS_READ) != 0)
   {
      png_ptr->read_fn = spng_c_stdio_read;
      png_ptr->write_fn = NULL;
      png_ptr->output_flush_fn = NULL;
   }

   else
   {
      png_ptr->write_fn = spng_c_stdio_write;
      png_ptr->output_flush_fn = spng_c_stdio_flush;
      png_ptr->read_fn = NULL;
   }
}

png_voidp PNGAPI
png_get_io_ptr(png_const_structrp png_ptr)
{
   if (png_ptr == NULL)
      return NULL;

   return png_ptr->io_ptr;
}

void PNGAPI
png_set_read_status_fn(png_structrp png_ptr, png_read_status_ptr read_row_fn)
{
   if (png_ptr == NULL)
      return;

   png_ptr->read_row_fn = read_row_fn;
}

void PNGAPI
png_set_write_status_fn(png_structrp png_ptr, png_write_status_ptr write_row_fn)
{
   if (png_ptr == NULL)
      return;

   png_ptr->write_row_fn = write_row_fn;
}

/* -- default stdio handlers ------------------------------------------------ */

void PNGCBAPI
spng_c_stdio_read(png_structp png_ptr, png_bytep data, size_t length)
{
   size_t read;

   if (png_ptr == NULL)
      return;

   if (png_ptr->io_ptr == NULL)
      png_error(png_ptr, "no input stream: call png_init_io or png_set_read_fn");

   read = fread(data, 1, length, (FILE *)png_ptr->io_ptr);

   /* A short read is an error rather than something to carry on from: the
    * decoder asked for a specific number of bytes because the format says they
    * are there.
    */
   if (read != length)
      png_error(png_ptr, "Read Error");
}

void PNGCBAPI
spng_c_stdio_write(png_structp png_ptr, png_bytep data, size_t length)
{
   size_t written;

   if (png_ptr == NULL)
      return;

   if (png_ptr->io_ptr == NULL)
      png_error(png_ptr, "no output stream: call png_init_io or png_set_write_fn");

   written = fwrite(data, 1, length, (FILE *)png_ptr->io_ptr);

   if (written != length)
      png_error(png_ptr, "Write Error");
}

void PNGCBAPI
spng_c_stdio_flush(png_structp png_ptr)
{
   if (png_ptr == NULL || png_ptr->io_ptr == NULL)
      return;

   fflush((FILE *)png_ptr->io_ptr);
}

/* -- trampolines -----------------------------------------------------------
 *
 * The flag around each call marks that client code is running, which the debug
 * re-entrancy checks read.  It is cleared afterwards, but a client that jumps out
 * leaves it set; that is harmless, because the only thing left to do with the
 * structure at that point is destroy it.
 */

void
spng_c_call_read(png_structrp png_ptr, png_bytep data, size_t length)
{
   if (png_ptr == NULL || length == 0)
      return;

   if (png_ptr->read_fn == NULL)
      png_error(png_ptr, "no input stream: call png_init_io or png_set_read_fn");

   png_ptr->flags |= SPNG_FLAG_IN_CALLBACK;
   png_ptr->read_fn(png_ptr, data, length);
   png_ptr->flags &= ~SPNG_FLAG_IN_CALLBACK;
}

void
spng_c_call_write(png_structrp png_ptr, png_bytep data, size_t length)
{
   if (png_ptr == NULL || length == 0)
      return;

   if (png_ptr->write_fn == NULL)
      png_error(png_ptr, "no output stream: call png_init_io or png_set_write_fn");

   png_ptr->flags |= SPNG_FLAG_IN_CALLBACK;
   png_ptr->write_fn(png_ptr, data, length);
   png_ptr->flags &= ~SPNG_FLAG_IN_CALLBACK;
}

void
spng_c_call_flush(png_structrp png_ptr)
{
   if (png_ptr == NULL || png_ptr->output_flush_fn == NULL)
      return;

   png_ptr->flags |= SPNG_FLAG_IN_CALLBACK;
   png_ptr->output_flush_fn(png_ptr);
   png_ptr->flags &= ~SPNG_FLAG_IN_CALLBACK;
}

void
spng_c_call_read_row_status(png_structrp png_ptr, png_uint_32 row, int pass)
{
   if (png_ptr == NULL || png_ptr->read_row_fn == NULL)
      return;

   png_ptr->flags |= SPNG_FLAG_IN_CALLBACK;
   png_ptr->read_row_fn(png_ptr, row, pass);
   png_ptr->flags &= ~SPNG_FLAG_IN_CALLBACK;
}

void
spng_c_call_write_row_status(png_structrp png_ptr, png_uint_32 row, int pass)
{
   if (png_ptr == NULL || png_ptr->write_row_fn == NULL)
      return;

   png_ptr->flags |= SPNG_FLAG_IN_CALLBACK;
   png_ptr->write_row_fn(png_ptr, row, pass);
   png_ptr->flags &= ~SPNG_FLAG_IN_CALLBACK;
}
