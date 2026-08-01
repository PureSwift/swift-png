/* swift_callbacks.c - registering client callbacks, and calling them
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

#include "swift_internal.h"

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
   bit = (png_ptr->flags & SWIFT_FLAG_IS_READ) != 0
       ? SWIFT_FLAG_BENIGN_READ_ERR : SWIFT_FLAG_BENIGN_WRITE_ERR;

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
   png_ptr->read_fn = read_data_fn != NULL ? read_data_fn : swift_c_stdio_read;

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
   png_ptr->write_fn = write_data_fn != NULL ? write_data_fn : swift_c_stdio_write;
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
   if ((png_ptr->flags & SWIFT_FLAG_IS_READ) != 0)
   {
      png_ptr->read_fn = swift_c_stdio_read;
      png_ptr->write_fn = NULL;
      png_ptr->output_flush_fn = NULL;
   }

   else
   {
      png_ptr->write_fn = swift_c_stdio_write;
      png_ptr->output_flush_fn = swift_c_stdio_flush;
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
swift_c_stdio_read(png_structp png_ptr, png_bytep data, size_t length)
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
swift_c_stdio_write(png_structp png_ptr, png_bytep data, size_t length)
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
swift_c_stdio_flush(png_structp png_ptr)
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
swift_c_call_read(png_structrp png_ptr, png_bytep data, size_t length)
{
   if (png_ptr == NULL || length == 0)
      return;

   if (png_ptr->read_fn == NULL)
      png_error(png_ptr, "no input stream: call png_init_io or png_set_read_fn");

   png_ptr->flags |= SWIFT_FLAG_IN_CALLBACK;
   png_ptr->read_fn(png_ptr, data, length);
   png_ptr->flags &= ~SWIFT_FLAG_IN_CALLBACK;
}

void
swift_c_call_write(png_structrp png_ptr, png_bytep data, size_t length)
{
   if (png_ptr == NULL || length == 0)
      return;

   if (png_ptr->write_fn == NULL)
      png_error(png_ptr, "no output stream: call png_init_io or png_set_write_fn");

   png_ptr->flags |= SWIFT_FLAG_IN_CALLBACK;
   png_ptr->write_fn(png_ptr, data, length);
   png_ptr->flags &= ~SWIFT_FLAG_IN_CALLBACK;
}

void
swift_c_call_flush(png_structrp png_ptr)
{
   if (png_ptr == NULL || png_ptr->output_flush_fn == NULL)
      return;

   png_ptr->flags |= SWIFT_FLAG_IN_CALLBACK;
   png_ptr->output_flush_fn(png_ptr);
   png_ptr->flags &= ~SWIFT_FLAG_IN_CALLBACK;
}

void
swift_c_call_read_row_status(png_structrp png_ptr, png_uint_32 row, int pass)
{
   if (png_ptr == NULL || png_ptr->read_row_fn == NULL)
      return;

   png_ptr->flags |= SWIFT_FLAG_IN_CALLBACK;
   png_ptr->read_row_fn(png_ptr, row, pass);
   png_ptr->flags &= ~SWIFT_FLAG_IN_CALLBACK;
}

void
swift_c_call_write_row_status(png_structrp png_ptr, png_uint_32 row, int pass)
{
   if (png_ptr == NULL || png_ptr->write_row_fn == NULL)
      return;

   png_ptr->flags |= SWIFT_FLAG_IN_CALLBACK;
   png_ptr->write_row_fn(png_ptr, row, pass);
   png_ptr->flags &= ~SWIFT_FLAG_IN_CALLBACK;
}

/* The two user transforms.
 *
 * One body for both directions, since the only difference is which function the
 * client installed.  The row description is a local: nothing owns it, and a jump
 * out of the client's transform abandons it with no consequence.
 */
static png_uint_32
call_user_transform(png_structrp png_ptr, png_user_transform_ptr fn,
    png_bytep row, png_uint_32 width, png_uint_32 bit_depth,
    png_uint_32 channels, png_uint_32 color_type)
{
   png_row_info row_info;

   if (png_ptr == NULL || fn == NULL)
      return (bit_depth & 0xFFU) | ((channels & 0xFFU) << 8);

   row_info.width = width;
   row_info.bit_depth = (png_byte)bit_depth;
   row_info.channels = (png_byte)channels;
   row_info.color_type = (png_byte)color_type;
   row_info.pixel_depth = (png_byte)(bit_depth * channels);
   /* Spelled out rather than borrowed: the macro that does this lives in a private
    * header, and the whole point of the vendored ones is that nothing private is
    * needed to build against them.
    */
   row_info.rowbytes = row_info.pixel_depth >= 8
       ? (size_t)width * (size_t)(row_info.pixel_depth >> 3)
       : (((size_t)width * (size_t)row_info.pixel_depth) + 7) >> 3;

   png_ptr->flags |= SWIFT_FLAG_IN_CALLBACK;
   fn(png_ptr, &row_info, row);
   png_ptr->flags &= ~SWIFT_FLAG_IN_CALLBACK;

   /* What the client declared wins over what it left behind in the description. */
   if (png_ptr->user_transform_depth != 0)
      row_info.bit_depth = png_ptr->user_transform_depth;

   if (png_ptr->user_transform_channels != 0)
      row_info.channels = png_ptr->user_transform_channels;

   return (png_uint_32)row_info.bit_depth | ((png_uint_32)row_info.channels << 8);
}

png_uint_32
swift_c_call_read_user_transform(png_structrp png_ptr, png_bytep row,
    png_uint_32 width, png_uint_32 bit_depth, png_uint_32 channels,
    png_uint_32 color_type)
{
   return call_user_transform(png_ptr,
       png_ptr == NULL ? NULL : png_ptr->read_user_transform_fn,
       row, width, bit_depth, channels, color_type);
}

png_uint_32
swift_c_call_write_user_transform(png_structrp png_ptr, png_bytep row,
    png_uint_32 width, png_uint_32 bit_depth, png_uint_32 channels,
    png_uint_32 color_type)
{
   return call_user_transform(png_ptr,
       png_ptr == NULL ? NULL : png_ptr->write_user_transform_fn,
       row, width, bit_depth, channels, color_type);
}

/* The three points a progressive read reports back at.
 *
 * Each is the client's own code and each may be jumped out of, so the flag is set and cleared around
 * it exactly as the others are.  The info structure is the one the client handed to png_process_data;
 * the library never owns it.
 */
void
swift_c_call_progressive_info(png_structrp png_ptr, png_inforp info_ptr)
{
   if (png_ptr == NULL || png_ptr->info_fn == NULL)
      return;

   png_ptr->flags |= SWIFT_FLAG_IN_CALLBACK;
   png_ptr->info_fn(png_ptr, info_ptr);
   png_ptr->flags &= ~SWIFT_FLAG_IN_CALLBACK;
}

void
swift_c_call_progressive_row(png_structrp png_ptr, png_bytep new_row,
    png_uint_32 row_number, int pass)
{
   if (png_ptr == NULL || png_ptr->row_fn == NULL)
      return;

   png_ptr->flags |= SWIFT_FLAG_IN_CALLBACK;
   png_ptr->row_fn(png_ptr, new_row, row_number, pass);
   png_ptr->flags &= ~SWIFT_FLAG_IN_CALLBACK;
}

void
swift_c_call_progressive_end(png_structrp png_ptr, png_inforp info_ptr)
{
   if (png_ptr == NULL || png_ptr->end_fn == NULL)
      return;

   png_ptr->flags |= SWIFT_FLAG_IN_CALLBACK;
   png_ptr->end_fn(png_ptr, info_ptr);
   png_ptr->flags &= ~SWIFT_FLAG_IN_CALLBACK;
}

/* A chunk this library does not understand, offered to the client's own handler.
 *
 * The structure it is shown is a local, for the reason the row description is: a client may jump out
 * of its handler, and a description owned by a Swift frame would be abandoned with whatever kept it
 * alive.
 */
int
swift_c_call_user_chunk(png_structrp png_ptr, png_uint_32 name, png_bytep data, size_t size)
{
   png_unknown_chunk chunk;
   int result;

   if (png_ptr == NULL || png_ptr->read_user_chunk_fn == NULL)
      return 0;

   chunk.name[0] = (png_byte)(name >> 24);
   chunk.name[1] = (png_byte)(name >> 16);
   chunk.name[2] = (png_byte)(name >> 8);
   chunk.name[3] = (png_byte)name;
   chunk.name[4] = 0;
   chunk.data = data;
   chunk.size = size;
   chunk.location = 0;

   png_ptr->flags |= SWIFT_FLAG_IN_CALLBACK;
   result = png_ptr->read_user_chunk_fn(png_ptr, &chunk);
   png_ptr->flags &= ~SWIFT_FLAG_IN_CALLBACK;

   return result;
}
