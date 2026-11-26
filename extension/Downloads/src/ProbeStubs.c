// What the audio probe used to provide, answered "nothing observed".
//
// Vitrine keeps its own audio pipeline (Shared/Audio/SGAudioPipeline.x rebinds the same AudioToolbox imports the
// probe redirected), so the probe's import redirect, AVFoundation hooks and WAV capture are not part of this
// build. The download engine never depended on them; only the diagnostics text read their counters.
#include <string.h>
#include "AudioProbe.h"
#include "SourceGraph.h"

SAP_EXPORT void SpotifyAudioProbeInitialize(void) {}
SAP_EXPORT void SpotifyAudioProbeSetObserver(SAPPCMObserver observer) { (void)observer; }
SAP_EXPORT void SpotifyAudioProbeReadSnapshot(SAPSnapshot *snapshot) { if (snapshot) memset(snapshot, 0, sizeof(*snapshot)); }
SAP_EXPORT bool SpotifyAudioProbeMuteForSeconds(double seconds) { (void)seconds; return false; }
void SAPReadSourceGraph(SAPSourceGraph *out) { if (out) { memset(out, 0, sizeof(*out)); out->status = 1; } }
