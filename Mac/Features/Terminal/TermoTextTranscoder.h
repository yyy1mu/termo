#ifndef TERMO_TEXT_TRANSCODER_H
#define TERMO_TEXT_TRANSCODER_H

typedef struct TermoTextTranscoder TermoTextTranscoder;

/// Stateful conversion preserves a split trailing character for the next push.
/// Returns NULL when either encoding is unsupported.
TermoTextTranscoder *termo_text_transcoder_new(const char *from_encoding,
                                               const char *to_encoding);
/// Returns bytes written, or -1 for invalid arguments/internal failure.
int termo_text_transcoder_push(TermoTextTranscoder *transcoder,
                               const unsigned char *input, int input_length,
                               unsigned char *output, int output_capacity);
void termo_text_transcoder_free(TermoTextTranscoder *transcoder);

#endif
