// Reads a paragraph aloud with any installed voice, sped up by speechwarp, and highlights the sentence being heard.
// Its log lines (SPEECHWARP-VOICE ...) let a script check that it speaks.
import { useCallback, useEffect, useRef, useState } from 'react';
import { Button, Platform, ScrollView, Settings, StyleSheet, Text, View } from 'react-native';
import {
  chooseVoice,
  createReader,
  listVoices,
  type Reader,
  type ReaderState,
  type VoiceInfo,
} from 'react-native-speechwarp-voice';
import { espeakAvailable } from 'react-native-speechwarp-voice-espeak';
import { kokoro } from 'react-native-speechwarp-voice-kokoro';

const TEXT =
  'This is speechwarp, reading aloud on your phone. ' +
  'The voice speaks a little ahead of what you hear, one sentence at a time. ' +
  'Speed it up, and the pauses shrink before the words do. ' +
  'You can change the voice between sentences, or jump to another one. ' +
  'That is all there is to it.';

// iOS: launching with `-speechwarpEngine espeak` (a user default) starts with that engine's voice, for scripted runs.
function preferredEngines(): string[] {
  const engines = ['apple', 'android', 'espeak', 'kokoro'];
  const wanted = Platform.OS === 'ios' ? Settings.get('speechwarpEngine') : undefined;
  return typeof wanted === 'string' ? [wanted, ...engines.filter((e) => e !== wanted)] : engines;
}

// Kokoro loads one model file (fp32 on Android, fp16 on iOS by default). Use whichever has been downloaded.
function pickDownloadedKokoroModel() {
  if (!kokoro.available()) return;
  const { models, defaultVoice } = kokoro.catalogue();
  const initial = kokoro.modelFile();
  log('kokoro', kokoro.directory(), initial, JSON.stringify(kokoro.missingFiles(defaultVoice).map((f) => f.path)));
  if (kokoro.isInstalled(defaultVoice)) return;
  for (const model of models) {
    kokoro.setModelFile(model.file.path);
    if (kokoro.isInstalled(defaultVoice)) {
      log('kokoro model', model.file.path);
      return;
    }
  }
  kokoro.setModelFile(initial);
}

function log(...parts: unknown[]) {
  console.log('SPEECHWARP-VOICE', ...parts);
}

export default function App() {
  const [voices, setVoices] = useState<VoiceInfo[]>([]);
  const [voice, setVoice] = useState<VoiceInfo>();
  const [reader, setReader] = useState<Reader>();
  const [state, setState] = useState<ReaderState>();
  const [speed, setSpeed] = useState(1.5);
  const [error, setError] = useState<string>();
  const [heard, setHeard] = useState(false);
  const readerRef = useRef<Reader | undefined>(undefined);

  useEffect(() => {
    pickDownloadedKokoroModel();
    listVoices()
      .then((all) => {
        setVoices(all);
        const engines = all.reduce<Record<string, number>>((n, v) => ({ ...n, [v.engine]: (n[v.engine] ?? 0) + 1 }), {});
        log('voices', JSON.stringify(engines));
        const first = chooseVoice(all, 'en', preferredEngines());
        log('chose', first?.id);
        setVoice(first);
      })
      .catch((e) => setError(String(e)));
    return () => readerRef.current?.release();
  }, []);

  // A new reader for each voice chosen from the list (setVoice would change it from the next sentence instead).
  useEffect(() => {
    if (!voice) return;
    let cancelled = false;
    createReader(TEXT, voice.id, { speed })
      .then((made) => {
        if (cancelled) return made.release();
        readerRef.current?.release();
        readerRef.current = made;
        log('reader', voice.id, `sampleRate=${made.sampleRate}`, `sentences=${made.sentenceCount}`);
        made.addListener('state', (s) => {
          setState(s);
          if (s.playing && !s.waiting && s.character > 0) setHeard(true);
          log('state', JSON.stringify(s));
        });
        made.addListener('error', (e) => {
          setError(e.message);
          log('error', e.message);
        });
        setReader(made);
        made.play();
      })
      .catch((e) => {
        setError(String(e));
        log('error', String(e));
      });
    return () => {
      cancelled = true;
    };
    // The speed is changed on the reader, not by making a new one.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [voice]);

  const changeSpeed = useCallback(
    (to: number) => {
      setSpeed(to);
      reader?.setSpeed(to);
    },
    [reader]
  );

  const nextSentence = useCallback(() => {
    if (!reader || !state) return;
    const next = reader.sentences[state.sentence + 1];
    if (next) reader.seek(next.start);
  }, [reader, state]);

  // The next voice of another engine (or the next of the same engine), after `current`.
  const voiceAfter = useCallback(
    (current: string, engine?: string) => {
      const usable = voices.filter((v) => v.installed && !v.requiresNetwork && v.language.toLowerCase().startsWith('en'));
      const engines = [...new Set(usable.map((v) => v.engine))];
      const now = usable.find((v) => v.id === current)?.engine ?? '';
      const nextEngine = engine ?? engines[(engines.indexOf(now) + 1) % engines.length];
      return usable.find((v) => v.engine === nextEngine && v.id !== current) ?? usable.find((v) => v.id !== current);
    },
    [voices]
  );

  // A new reader in another voice, from the start.
  const otherVoice = useCallback(() => {
    const picked = voice && voiceAfter(voice.id);
    if (picked) setVoice(picked);
  }, [voice, voiceAfter]);

  // The same reader, carrying on in another voice from the next sentence.
  const [switched, setSwitched] = useState<string>();
  const switchVoice = useCallback(
    (engine?: string) => {
      if (!reader) return;
      const picked = voiceAfter(reader.voiceId, engine);
      if (!picked) return;
      log('setVoice', picked.id);
      reader.setVoice(picked.id);
      setSwitched(`${picked.name} (${picked.engine}) from the next sentence`);
    },
    [reader, voiceAfter]
  );

  // iOS, scripted runs: `-speechwarpSwitch espeak` changes to that engine once the second sentence is heard.
  const scriptedSwitch = useRef(false);
  useEffect(() => {
    const engine = Platform.OS === 'ios' ? Settings.get('speechwarpSwitch') : undefined;
    if (typeof engine === 'string' && !scriptedSwitch.current && state && state.sentence >= 1) {
      scriptedSwitch.current = true;
      switchVoice(engine);
    }
  }, [state, switchVoice]);

  const sentence = reader && state ? reader.sentences[state.sentence] : undefined;
  return (
    <View style={styles.container}>
      <ScrollView contentContainerStyle={styles.content}>
        <Text style={styles.title}>speechwarp voice</Text>
        <Text style={styles.status}>{heard ? 'SPEECHWARP VOICE OK' : 'waiting for speech...'}</Text>
        <Text style={styles.text}>
          {sentence ? (
            <>
              {TEXT.slice(0, sentence.start)}
              <Text style={styles.highlight}>{TEXT.slice(sentence.start, sentence.start + sentence.length)}</Text>
              {TEXT.slice(sentence.start + sentence.length)}
            </>
          ) : (
            TEXT
          )}
        </Text>
        <Text style={styles.detail}>
          {voice ? `${voice.name} (${voice.engine}, ${voice.language})` : 'no voice yet'}
          {'\n'}
          {state
            ? `character ${state.character}, sentence ${state.sentence + 1}, ${state.time.toFixed(1)} s` +
              `${state.waiting ? ', waiting for the voice' : ''}${state.finished ? ', finished' : ''}`
            : ''}
          {'\n'}
          {`${speed.toFixed(1)}x · ${voices.length} voices · eSpeak ${espeakAvailable() ? 'installed' : 'not installed'}` +
            ` · Kokoro ${kokoro.available() ? 'installed' : 'not installed'}`}
        </Text>
        {error ? <Text style={styles.error}>{error}</Text> : null}
        <View style={styles.row}>
          <Button title={state?.playing ? 'Pause' : 'Play'} onPress={() => (state?.playing ? reader?.pause() : reader?.play())} />
          <Button title="Next sentence" onPress={nextSentence} />
        </View>
        <View style={styles.row}>
          <Button title="Slower" onPress={() => changeSpeed(Math.max(0.5, speed - 0.5))} />
          <Button title="Faster" onPress={() => changeSpeed(Math.min(8, speed + 0.5))} />
        </View>
        <View style={styles.row}>
          <Button title="Another voice" onPress={otherVoice} />
          <Button title="Switch voice" onPress={() => switchVoice()} />
        </View>
        {switched ? <Text style={styles.detail}>{`Switched to ${switched}`}</Text> : null}
        <Text style={styles.detail}>{Platform.OS}</Text>
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  content: { padding: 24, paddingTop: 48 },
  title: { fontSize: 22, marginBottom: 8 },
  status: { fontSize: 16, marginBottom: 16, fontWeight: '600' },
  text: { fontSize: 18, lineHeight: 26, marginBottom: 16 },
  highlight: { backgroundColor: '#ffe08a' },
  detail: { fontSize: 14, color: '#555', marginBottom: 16 },
  error: { fontSize: 14, color: '#b00020', marginBottom: 16 },
  row: { flexDirection: 'row', justifyContent: 'space-around', marginBottom: 12 },
});
