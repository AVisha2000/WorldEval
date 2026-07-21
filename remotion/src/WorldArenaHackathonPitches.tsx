import {
  AbsoluteFill,
  Audio,
  Easing,
  Img,
  Sequence,
  Video,
  interpolate,
  staticFile,
  useCurrentFrame,
} from 'remotion';

const colors = {
  ink: '#06131d',
  cyan: '#62e3c1',
  gold: '#ffc45d',
  coral: '#ff7f76',
  text: '#f5f9f8',
  muted: '#b7cad1',
};

const gameplay = staticFile('worldarena-gameplay.mp4');

const GameplayBed = () => (
  <AbsoluteFill>
    <Video src={gameplay} muted loop style={{width: '100%', height: '100%', objectFit: 'cover'}} />
    <AbsoluteFill style={{background: 'linear-gradient(100deg, rgba(2,11,18,0.78), rgba(2,11,18,0.24) 62%, rgba(2,11,18,0.5))'}} />
  </AbsoluteFill>
);

const Label = ({children, tone = colors.cyan}: {children: React.ReactNode; tone?: string}) => (
  <div style={{color: tone, fontSize: 19, fontWeight: 800, letterSpacing: 3.2, textTransform: 'uppercase'}}>{children}</div>
);

const Scene = ({
  eyebrow,
  title,
  body,
  children,
  filler = false,
}: {
  eyebrow: string;
  title: string;
  body: string;
  children?: React.ReactNode;
  filler?: boolean;
}) => {
  const frame = useCurrentFrame();
  const opacity = interpolate(frame, [0, 14], [0, 1], {
    extrapolateRight: 'clamp',
    easing: Easing.bezier(0.16, 1, 0.3, 1),
  });
  const y = interpolate(frame, [0, 18], [34, 0], {extrapolateRight: 'clamp'});
  return (
    <AbsoluteFill>
      <GameplayBed />
      <div style={{position: 'absolute', left: 90, top: 86, width: 820, opacity, translate: `0 ${y}px`}}>
        <Label tone={filler ? colors.gold : colors.cyan}>{filler ? 'Roadmap concept visual' : eyebrow}</Label>
        <div style={{fontSize: 76, lineHeight: 1.04, fontWeight: 850, letterSpacing: -2.4, marginTop: 20}}>{title}</div>
        <div style={{fontSize: 27, lineHeight: 1.4, color: colors.muted, marginTop: 28, maxWidth: 735}}>{body}</div>
      </div>
      {children}
      {filler ? <div style={{position: 'absolute', right: 66, bottom: 54, border: `1px solid ${colors.gold}`, borderRadius: 999, background: 'rgba(5,14,22,0.86)', color: colors.gold, fontSize: 16, fontWeight: 800, letterSpacing: 1.5, padding: '11px 16px'}}>NOT A LIVE CAPTURE</div> : null}
    </AbsoluteFill>
  );
};

const ProtocolRail = () => (
  <div style={{position: 'absolute', left: 90, right: 90, bottom: 96, display: 'flex', gap: 18}}>
    <ProtocolCard step="01" label="Participant view" />
    <ProtocolCard step="02" label="Bounded input" />
    <ProtocolCard step="03" label="Godot resolves" />
    <ProtocolCard step="04" label="Replay evidence" />
  </div>
);

const ProtocolCard = ({step, label}: {step: string; label: string}) => (
  <div style={{flex: 1, padding: '19px 21px', background: 'rgba(4,18,27,0.9)', border: '1px solid rgba(112, 222, 199, 0.45)', borderRadius: 18}}>
    <div style={{color: colors.cyan, fontSize: 16, fontWeight: 850, letterSpacing: 2}}>{step}</div>
    <div style={{fontSize: 23, fontWeight: 760, marginTop: 8}}>{label}</div>
  </div>
);

const EvidenceImage = ({file, caption}: {file: string; caption: string}) => (
  <div style={{position: 'absolute', right: 80, top: 108, width: 730}}>
    <Img src={staticFile(file)} style={{width: '100%', borderRadius: 22, border: '1px solid rgba(164, 220, 225, 0.36)', boxShadow: '0 28px 70px rgba(0,0,0,0.45)'}} />
    <div style={{color: colors.muted, fontSize: 16, fontWeight: 700, letterSpacing: 1.5, marginTop: 14, textAlign: 'right'}}>{caption}</div>
  </div>
);

export const WorldArenaEmbodiedPitch = () => (
  <AbsoluteFill style={{background: colors.ink, color: colors.text, fontFamily: 'Inter, ui-sans-serif, system-ui, sans-serif', overflow: 'hidden'}}>
    <Audio src={staticFile('embodied-pitch.m4a')} />
    <Sequence from={0} durationInFrames={540} premountFor={30}>
      <Scene eyebrow="WorldArena" title="Can an AI act through physical dependencies?" body="A plan can sound right and still fail when the world pushes back." filler>
        <div style={{position: 'absolute', right: 110, bottom: 122, display: 'flex', gap: 22}}>
          <ProtocolCard step="AI" label="Walk to station" />
          <div style={{fontSize: 54, color: colors.gold, alignSelf: 'center'}}>≠</div>
          <ProtocolCard step="WORLD" label="Car still needs fuel" />
        </div>
      </Scene>
    </Sequence>
    <Sequence from={540} durationInFrames={540} premountFor={30}>
      <Scene eyebrow="Embodied agent evaluation" title="The model chooses inputs. Godot owns reality." body="Bounded movement, look, and interaction commands meet fixed-tick physics, collision, resources, and consequences.">
        <ProtocolRail />
      </Scene>
    </Sequence>
    <Sequence from={1080} durationInFrames={780} premountFor={30}>
      <Scene eyebrow="Solo curriculum" title="Find. Gather. Carry. Deposit. Build." body="Construction is a sequence of visible dependencies—never a hidden semantic shortcut." filler>
        <div style={{position: 'absolute', right: 82, top: 218, width: 670, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16}}>
          <ProtocolCard step="01" label="Visible resource" />
          <ProtocolCard step="02" label="Held interaction" />
          <ProtocolCard step="03" label="Carry to relay" />
          <ProtocolCard step="04" label="Build barricade" />
        </div>
      </Scene>
    </Sequence>
    <Sequence from={1860} durationInFrames={600} premountFor={30}>
      <Scene eyebrow="Inspectable by design" title="No hidden repair. Evidence, not claims." body="Participant-scoped observations, receipts, checkpoints, evaluation data, and offline-verifiable replay artifacts.">
        <EvidenceImage file="artifact-replay.png" caption="IMPLEMENTED REPLAY / ARTIFACT SURFACE" />
      </Scene>
    </Sequence>
    <Sequence from={2460} durationInFrames={600} premountFor={30}>
      <Scene eyebrow="Fair competition" title="A mirrored two-leg controller duel." body="Identical bodies and controls. Swapped sides. Measure the model, not a favourable spawn." filler>
        <EvidenceImage file="controller-dashboard-concept.png" caption="CONTROLLER LAB / CONCEPT SURFACE" />
      </Scene>
    </Sequence>
    <Sequence from={3060} durationInFrames={600} premountFor={30}>
      <Scene eyebrow="Three-agent arena" title="Sol, Terra, and Luna contest one shared world." body="This authored deterministic local presentation demonstrates gather, build, scout, conflict, and outcome.">
        <div style={{position: 'absolute', right: 64, bottom: 56, color: colors.gold, fontSize: 16, letterSpacing: 1.4, fontWeight: 800}}>UNVERIFIED DETERMINISTIC LOCAL DEMO</div>
      </Scene>
    </Sequence>
    <Sequence from={3660} durationInFrames={900} premountFor={30}>
      <Scene eyebrow="Built with Codex + GPT-5.6" title="Evaluate what AI does, not only what it says." body="Codex accelerated the authority, dashboard, tests, and this production. GPT-5.6 is integrated for live controller experiments.">
        <EvidenceImage file="simulation-lab.png" caption="IMPLEMENTED SIMULATION LAB" />
      </Scene>
    </Sequence>
    <Sequence from={4560} durationInFrames={660} premountFor={30}>
      <Scene eyebrow="WorldArena" title="Embodied AI. Fair games. Replayable evidence." body="The shown gameplay is a deterministic local demo, reproducible without keys or network calls." />
    </Sequence>
  </AbsoluteFill>
);

export const WorldArenaStrategicPitch = () => (
  <AbsoluteFill style={{background: colors.ink, color: colors.text, fontFamily: 'Inter, ui-sans-serif, system-ui, sans-serif', overflow: 'hidden'}}>
    <Audio src={staticFile('strategic-pitch.m4a')} />
    <Sequence from={0} durationInFrames={480} premountFor={30}>
      <Scene eyebrow="WorldEval" title="Plans are easy. Consequences are harder." body="Can a model adapt when information is partial, resources are finite, and other agents change the board?" />
    </Sequence>
    <Sequence from={480} durationInFrames={600} premountFor={30}>
      <Scene eyebrow="WorldArena" title="A shared world for evaluating intelligent agents." body="Language models choose strategy. Godot owns movement, resources, construction, combat, and scoring.">
        <ProtocolRail />
      </Scene>
    </Sequence>
    <Sequence from={1080} durationInFrames={600} premountFor={30}>
      <Scene eyebrow="One simultaneous round" title="Observe. Seal plans. Resolve. Audit." body="Visibility-filtered observations and sealed plans prevent latency or presentation from changing the outcome.">
        <ProtocolRail />
      </Scene>
    </Sequence>
    <Sequence from={1680} durationInFrames={720} premountFor={30}>
      <Scene eyebrow="The world makes strategy visible" title="Gather. Build. Scout. Negotiate. Adapt." body="A strong answer is not enough when supply, timing, territory, and rivals have consequences." />
    </Sequence>
    <Sequence from={2400} durationInFrames={720} premountFor={30}>
      <Scene eyebrow="Evidence-linked scoring" title="Measure more than a win screen." body="Planning, efficiency, social intelligence, delegation, reliability—and the receipts supporting every result.">
        <EvidenceImage file="artifact-replay.png" caption="IMPLEMENTED REPLAY / ARTIFACT SURFACE" />
      </Scene>
    </Sequence>
    <Sequence from={3120} durationInFrames={720} premountFor={30}>
      <Scene eyebrow="What exists today" title="An authored deterministic local demo." body="This gameplay cut is a presentation, not a published leaderboard result. Concept panels identify roadmap capabilities.">
        <div style={{position: 'absolute', right: 64, bottom: 56, color: colors.gold, fontSize: 16, letterSpacing: 1.4, fontWeight: 800}}>UNVERIFIED DETERMINISTIC LOCAL DEMO</div>
      </Scene>
    </Sequence>
    <Sequence from={3840} durationInFrames={720} premountFor={30}>
      <Scene eyebrow="Built with Codex + GPT-5.6" title="Observable. Reproducible. Comparable." body="Codex accelerated the simulation, contracts, dashboard, tests, and video workflow. GPT-5.6 supports live controller experiments.">
        <EvidenceImage file="simulation-lab.png" caption="IMPLEMENTED SIMULATION LAB" />
      </Scene>
    </Sequence>
    <Sequence from={4560} durationInFrames={660} premountFor={30}>
      <Scene eyebrow="WorldArena" title="Evaluate what AI does." body="Not only what it says." />
    </Sequence>
  </AbsoluteFill>
);
