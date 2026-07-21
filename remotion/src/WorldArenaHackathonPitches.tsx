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
import {
  ArenaMatte,
  CornerMetadata,
  KineticTitle,
  PulseGrid,
  RoutePulse,
  StageCard,
  arenaPalette,
} from './HackathonMotion';

const gameplay = staticFile('worldarena-gameplay.mp4');
const paper = arenaPalette.paper;
const ink = arenaPalette.ink;
const cyan = arenaPalette.cyan;

const GameplayBed = () => {
  const frame = useCurrentFrame();
  const scale = interpolate(frame % 540, [0, 540], [1.045, 1.1]);
  const x = interpolate(frame % 450, [0, 450], [-12, 12]);

  return (
    <AbsoluteFill>
      <Video
        src={gameplay}
        muted
        loop
        style={{width: '100%', height: '100%', objectFit: 'cover', transform: `scale(${scale}) translateX(${x}px)`}}
      />
      <AbsoluteFill style={{background: 'linear-gradient(90deg, rgba(3,10,13,0.94) 0%, rgba(3,10,13,0.72) 35%, rgba(3,10,13,0.12) 70%, rgba(3,10,13,0.54) 100%)'}} />
      <AbsoluteFill style={{background: 'linear-gradient(0deg, rgba(3,10,13,0.72), transparent 34%, rgba(3,10,13,0.3))'}} />
    </AbsoluteFill>
  );
};

const TinyLabel = ({children, tone = cyan}: {children: React.ReactNode; tone?: string}) => (
  <div style={{color: tone, fontSize: 17, fontWeight: 850, letterSpacing: 2.8, textTransform: 'uppercase'}}>{children}</div>
);

const TextPanel = ({eyebrow, title, body, index, filler = false}: {eyebrow: string; title: string; body: string; index: string; filler?: boolean}) => {
  const frame = useCurrentFrame();
  const lineWidth = interpolate(frame, [8, 38], [0, 112], {extrapolateRight: 'clamp', easing: Easing.bezier(0.16, 1, 0.3, 1)});
  return (
    <div style={{position: 'absolute', left: 80, top: 150, width: 740}}>
      <div style={{display: 'flex', alignItems: 'center', gap: 15}}>
        <TinyLabel tone={filler ? '#ffd877' : cyan}>{filler ? 'Roadmap concept visual' : eyebrow}</TinyLabel>
        <div style={{height: 2, width: lineWidth, background: filler ? '#ffd877' : cyan}} />
        <div style={{color: 'rgba(246,250,247,0.62)', fontSize: 15, fontWeight: 800, letterSpacing: 1.6}}>{index}</div>
      </div>
      <KineticTitle size={88} delay={8} style={{color: paper, marginTop: 23, maxWidth: 725}}>{title}</KineticTitle>
      <div style={{color: 'rgba(235,244,240,0.8)', fontSize: 25, lineHeight: 1.35, marginTop: 27, maxWidth: 620, letterSpacing: '-0.018em'}}>{body}</div>
    </div>
  );
};

const Telemetry = ({label = 'LIVE SIMULATION'}: {label?: string}) => {
  const frame = useCurrentFrame();
  const progress = Math.round(((frame % 150) / 150) * 100).toString().padStart(2, '0');
  return (
    <div style={{position: 'absolute', right: 48, bottom: 38, display: 'flex', gap: 20, alignItems: 'center', color: 'rgba(240,248,244,0.72)', fontSize: 14, fontWeight: 800, letterSpacing: 1.45}}>
      <span style={{color: cyan}}>●</span><span>{label}</span><span>SYNC {progress}%</span>
    </div>
  );
};

const ActionRail = ({items}: {items: string[]}) => {
  const frame = useCurrentFrame();
  return (
    <div style={{position: 'absolute', left: 80, right: 80, bottom: 88, display: 'flex', gap: 10}}>
      {items.map((item, index) => {
        const active = Math.floor(frame / 44) % items.length === index;
        return <div key={item} style={{flex: 1, padding: '16px 18px', borderRadius: 15, background: active ? paper : 'rgba(5,18,23,0.82)', color: active ? ink : 'rgba(241,245,241,0.72)', border: `1px solid ${active ? paper : 'rgba(104,234,214,0.28)'}`, fontSize: 18, fontWeight: 780, letterSpacing: 0.15}}><span style={{color: active ? '#138b86' : cyan, fontSize: 13, marginRight: 10}}>0{index + 1}</span>{item}</div>;
      })}
    </div>
  );
};

const EvidenceFrame = ({file, caption, concept = false}: {file: string; caption: string; concept?: boolean}) => {
  const frame = useCurrentFrame();
  const enter = interpolate(frame, [12, 34], [34, 0], {extrapolateRight: 'clamp', easing: Easing.bezier(0.16, 1, 0.3, 1)});
  return (
    <div style={{position: 'absolute', right: 62, top: 150, width: 760, transform: `translateY(${enter}px)`}}>
      <div style={{padding: 10, background: 'rgba(241,244,238,0.94)', borderRadius: 27, boxShadow: '0 30px 85px rgba(0,0,0,0.46)'}}>
        <Img src={staticFile(file)} style={{display: 'block', width: '100%', borderRadius: 18}} />
      </div>
      <div style={{marginTop: 15, textAlign: 'right', color: concept ? '#ffd877' : 'rgba(240,248,244,0.72)', fontSize: 14, fontWeight: 850, letterSpacing: 1.45}}>{concept ? 'ROADMAP CONCEPT / NOT A LIVE CAPTURE' : caption}</div>
    </div>
  );
};

const EditorialScene = ({eyebrow, title, body, index, children, filler = false, telemetry}: {eyebrow: string; title: string; body: string; index: string; children?: React.ReactNode; filler?: boolean; telemetry?: string}) => (
  <AbsoluteFill>
    <GameplayBed />
    <PulseGrid opacity={0.34} />
    <CornerMetadata left="WORLDARENA / BUILD WEEK" right="EMBODIED EVALUATION" dark />
    <TextPanel eyebrow={eyebrow} title={title} body={body} index={index} filler={filler} />
    {children}
    <Telemetry label={telemetry} />
  </AbsoluteFill>
);

const Hook = ({strategic = false}: {strategic?: boolean}) => {
  const frame = useCurrentFrame();
  const expand = interpolate(frame, [114, 154], [0.79, 1.13], {extrapolateRight: 'clamp', easing: Easing.bezier(0.16, 1, 0.3, 1)});
  const promptOpacity = interpolate(frame, [0, 14, 112, 130], [0, 1, 1, 0], {extrapolateRight: 'clamp'});
  const answerOpacity = interpolate(frame, [112, 132, 150], [0, 0.92, 0], {extrapolateRight: 'clamp'});
  return (
    <ArenaMatte>
      <CornerMetadata left="WORLDARENA / 01" right="WHAT THE WORLD CHANGES" dark />
      <StageCard style={{left: 132, top: 180, width: 1650, height: 720, transform: `scale(${expand})`, overflow: 'hidden'}}>
        <div style={{color: '#607076', fontSize: 18, fontWeight: 800, letterSpacing: 2.2}}>WORLDARENA</div>
        <KineticTitle size={118} delay={4} style={{maxWidth: 1160, color: ink, marginTop: 38}}>{strategic ? 'Plans are easy. Consequences are harder.' : 'What can an AI actually do in the physical world?'}</KineticTitle>
        <div style={{position: 'absolute', left: 42, right: 42, bottom: 48, opacity: promptOpacity, padding: '26px 30px', borderRadius: 20, background: '#dce6e0', color: ink, fontSize: 30, fontWeight: 650}}>{strategic ? 'observe → plan → commit → adapt' : '“The petrol station is five minutes away. Walk there.”'}</div>
        <div style={{position: 'absolute', left: 42, right: 42, bottom: 48, opacity: answerOpacity, padding: '26px 30px', borderRadius: 20, background: ink, color: paper, fontSize: 30, fontWeight: 760}}>{strategic ? 'The board changes while you decide.' : 'But the car is still behind.'}<span style={{color: cyan}}>  Physical dependency matters.</span></div>
      </StageCard>
      <RoutePulse points={[[104, 940], [420, 860], [800, 922], [1210, 836], [1740, 930]]} />
    </ArenaMatte>
  );
};

export const WorldArenaEmbodiedPitch = () => (
  <AbsoluteFill style={{background: arenaPalette.matte, color: paper, fontFamily: 'Inter, ui-sans-serif, system-ui, sans-serif', overflow: 'hidden'}}>
    <Audio src={staticFile('embodied-pitch.m4a')} />
    <Sequence from={0} durationInFrames={540} premountFor={30}><Hook /></Sequence>
    <Sequence from={540} durationInFrames={540} premountFor={30}>
      <EditorialScene eyebrow="Embodied agent evaluation" title="The model chooses inputs. Godot owns reality." body="Continuous movement, collision, resources, and interaction holds create consequences." index="02 / CONTROL">
        <ActionRail items={['participant view', 'bounded input', 'Godot resolves', 'replay evidence']} />
      </EditorialScene>
    </Sequence>
    <Sequence from={1080} durationInFrames={780} premountFor={30}>
      <EditorialScene eyebrow="Solo curriculum" title="Find. Gather. Carry. Deposit. Build." body="A real chain of visible dependencies—never a hidden semantic shortcut." index="03 / CAPABILITY" filler>
        <ActionRail items={['visible resource', 'held interaction', 'carry to relay', 'build barricade']} />
      </EditorialScene>
    </Sequence>
    <Sequence from={1860} durationInFrames={600} premountFor={30}>
      <EditorialScene eyebrow="Inspectable by design" title="Evidence, not claims." body="Participant-scoped observations, checkpoints, receipts, and verifiable replay artifacts." index="04 / PROOF">
        <EvidenceFrame file="artifact-replay.png" caption="IMPLEMENTED REPLAY / ARTIFACT SURFACE" />
      </EditorialScene>
    </Sequence>
    <Sequence from={2460} durationInFrames={600} premountFor={30}>
      <EditorialScene eyebrow="Fair competition" title="A mirrored two-leg controller duel." body="Identical bodies and controls. Swapped sides. Measure the model—not a spawn." index="05 / FAIRNESS" filler>
        <EvidenceFrame file="controller-dashboard-concept.png" caption="CONTROLLER LAB" concept />
      </EditorialScene>
    </Sequence>
    <Sequence from={3060} durationInFrames={600} premountFor={30}>
      <EditorialScene eyebrow="Three-agent arena" title="Sol. Terra. Luna. One shared world." body="This authored deterministic local presentation shows gather, build, scout, conflict, and outcome." index="06 / ARENA" telemetry="UNVERIFIED LOCAL DEMO">
        <RoutePulse points={[[1100, 850], [1270, 662], [1500, 760], [1710, 544]]} />
      </EditorialScene>
    </Sequence>
    <Sequence from={3660} durationInFrames={900} premountFor={30}>
      <EditorialScene eyebrow="Built with Codex + GPT-5.6" title="Evaluate what AI does, not only what it says." body="Codex accelerated the simulation, authority, tests, dashboard, and this production. GPT-5.6 supports live controller experiments." index="07 / BUILD">
        <EvidenceFrame file="simulation-lab.png" caption="IMPLEMENTED SIMULATION LAB" />
      </EditorialScene>
    </Sequence>
    <Sequence from={4560} durationInFrames={660} premountFor={30}>
      <EditorialScene eyebrow="WorldArena" title="Embodied AI. Fair games. Replayable evidence." body="A deterministic local demo, reproducible without keys or network calls." index="08 / CLOSE" telemetry="WORLD READY" />
    </Sequence>
  </AbsoluteFill>
);

export const WorldArenaStrategicPitch = () => (
  <AbsoluteFill style={{background: arenaPalette.matte, color: paper, fontFamily: 'Inter, ui-sans-serif, system-ui, sans-serif', overflow: 'hidden'}}>
    <Audio src={staticFile('strategic-pitch.m4a')} />
    <Sequence from={0} durationInFrames={480} premountFor={30}><Hook strategic /></Sequence>
    <Sequence from={480} durationInFrames={600} premountFor={30}>
      <EditorialScene eyebrow="WorldArena" title="A shared world for evaluating intelligent agents." body="Models choose strategy. Godot owns movement, resources, construction, and scoring." index="02 / ARENA">
        <ActionRail items={['see', 'plan', 'act', 'prove']} />
      </EditorialScene>
    </Sequence>
    <Sequence from={1080} durationInFrames={600} premountFor={30}>
      <EditorialScene eyebrow="One simultaneous round" title="Observe. Seal plans. Resolve. Audit." body="Visibility-filtered observations and sealed plans protect the integrity of each round." index="03 / PROTOCOL">
        <ActionRail items={['observe', 'seal plans', 'resolve', 'audit']} />
      </EditorialScene>
    </Sequence>
    <Sequence from={1680} durationInFrames={720} premountFor={30}>
      <EditorialScene eyebrow="The world makes strategy visible" title="Gather. Build. Scout. Negotiate. Adapt." body="Supply, territory, timing, and rivals turn answers into accountable actions." index="04 / PRESSURE">
        <RoutePulse points={[[920, 870], [1220, 690], [1390, 840], [1710, 600]]} />
      </EditorialScene>
    </Sequence>
    <Sequence from={2400} durationInFrames={720} premountFor={30}>
      <EditorialScene eyebrow="Evidence-linked scoring" title="Measure more than a win screen." body="Planning, efficiency, social intelligence, reliability—and evidence supporting every result." index="05 / SCORE">
        <EvidenceFrame file="artifact-replay.png" caption="IMPLEMENTED REPLAY / ARTIFACT SURFACE" />
      </EditorialScene>
    </Sequence>
    <Sequence from={3120} durationInFrames={720} premountFor={30}>
      <EditorialScene eyebrow="What exists today" title="An authored deterministic local demo." body="This cut is a presentation, not a published leaderboard result. Concept panels identify roadmap work." index="06 / DISCLOSURE" telemetry="UNVERIFIED LOCAL DEMO" />
    </Sequence>
    <Sequence from={3840} durationInFrames={720} premountFor={30}>
      <EditorialScene eyebrow="Built with Codex + GPT-5.6" title="Observable. Reproducible. Comparable." body="Codex accelerated the simulation, contracts, dashboard, tests, and video workflow. GPT-5.6 supports controller experiments." index="07 / BUILD">
        <EvidenceFrame file="simulation-lab.png" caption="IMPLEMENTED SIMULATION LAB" />
      </EditorialScene>
    </Sequence>
    <Sequence from={4560} durationInFrames={660} premountFor={30}>
      <EditorialScene eyebrow="WorldArena" title="Evaluate what AI does." body="Not only what it says." index="08 / CLOSE" telemetry="WORLD READY" />
    </Sequence>
  </AbsoluteFill>
);
