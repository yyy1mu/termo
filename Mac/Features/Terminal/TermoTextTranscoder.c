#include "TermoTextTranscoder.h"

#include <errno.h>
#include <iconv.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

struct TermoTextTranscoder {
    iconv_t converter;
    unsigned char pending[16];
    size_t pending_length;
    bool output_is_utf8;
    bool input_is_utf8;
};

TermoTextTranscoder *termo_text_transcoder_new(const char *from_encoding,
                                               const char *to_encoding) {
    if (!from_encoding || !to_encoding) return NULL;
    iconv_t converter = iconv_open(to_encoding, from_encoding);
    if (converter == (iconv_t)-1) return NULL;
    TermoTextTranscoder *result = calloc(1, sizeof(*result));
    if (!result) {
        iconv_close(converter);
        return NULL;
    }
    result->converter = converter;
    result->output_is_utf8 = strcasecmp(to_encoding, "UTF-8") == 0;
    result->input_is_utf8 = strcasecmp(from_encoding, "UTF-8") == 0;
    return result;
}

static size_t invalid_input_length(const TermoTextTranscoder *transcoder,
                                   const unsigned char *input, size_t length) {
    if (!transcoder->input_is_utf8 || length == 0) return 1;
    unsigned char first = input[0];
    size_t expected = first < 0x80 ? 1 : first < 0xE0 ? 2 : first < 0xF0 ? 3 : 4;
    return expected <= length ? expected : 1;
}

static bool append_replacement(const TermoTextTranscoder *transcoder,
                               char **output, size_t *remaining) {
    static const unsigned char utf8_replacement[] = {0xEF, 0xBF, 0xBD};
    const unsigned char *bytes = transcoder->output_is_utf8 ? utf8_replacement
                                                            : (const unsigned char *)"?";
    size_t length = transcoder->output_is_utf8 ? sizeof(utf8_replacement) : 1;
    if (*remaining < length) return false;
    memcpy(*output, bytes, length);
    *output += length;
    *remaining -= length;
    return true;
}

int termo_text_transcoder_push(TermoTextTranscoder *transcoder,
                               const unsigned char *input, int input_length,
                               unsigned char *output, int output_capacity) {
    if (!transcoder || input_length < 0 || output_capacity < 0 ||
        (input_length > 0 && !input) || (output_capacity > 0 && !output)) return -1;
    size_t total = transcoder->pending_length + (size_t)input_length;
    unsigned char *buffer = malloc(total > 0 ? total : 1);
    if (!buffer) return -1;
    memcpy(buffer, transcoder->pending, transcoder->pending_length);
    if (input_length > 0) memcpy(buffer + transcoder->pending_length, input, (size_t)input_length);
    transcoder->pending_length = 0;

    char *source = (char *)buffer;
    size_t source_remaining = total;
    char *destination = (char *)output;
    size_t destination_remaining = (size_t)output_capacity;
    while (source_remaining > 0) {
        if (iconv(transcoder->converter, &source, &source_remaining,
                  &destination, &destination_remaining) != (size_t)-1) break;
        if (errno == EINVAL) {
            if (source_remaining > sizeof(transcoder->pending)) {
                free(buffer);
                return -1;
            }
            memcpy(transcoder->pending, source, source_remaining);
            transcoder->pending_length = source_remaining;
            break;
        }
        if (errno != EILSEQ || !append_replacement(transcoder, &destination, &destination_remaining)) {
            free(buffer);
            return -1;
        }
        size_t skipped = invalid_input_length(transcoder, (unsigned char *)source, source_remaining);
        source += skipped;
        source_remaining -= skipped;
        iconv(transcoder->converter, NULL, NULL, NULL, NULL);
    }
    int written = output_capacity - (int)destination_remaining;
    free(buffer);
    return written;
}

void termo_text_transcoder_free(TermoTextTranscoder *transcoder) {
    if (!transcoder) return;
    iconv_close(transcoder->converter);
    free(transcoder);
}
