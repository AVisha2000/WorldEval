import {
  AbsoluteFill,
  Sequence,
  Video,
  interpolate,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';

const FPS = 30;

const colors = {
  ink: '#07131C',
  panel: 'rgba(6, 19, 28, 0.82)',
  mint: '#6EE7C2',
  gold: '#FFBE55',
  blue: '#74B9FF',
  coral: '#FF7B72',
  text: '#F2F6F4',
  muted: '#ABC0C8',
};

const Fade = ({children}: {children: React.ReactNode}) => {
  const frame = useCurrentFrame();
  const opacity = interpolate(frame, [0, 16], [0, 1], {extrapolateRight: 'clamp'});
  return <div style={{opacity, width: '100%', height: '100%'}}>{children}</div>;
};

const Eyebrow = ({children}: {children: React.ReactNode}) => (
  <div style={{color: colors.mint, fontSize: 22, fontWeight: 700, letterSpacing: 5}}>
    {children}
  </div>
);

const Headline = ({children}: {children: React.ReactNode}) => (
  <div style={{fontSize: 70, lineHeight: 1.08, fontWeight: 800, maxWidth: 1180}}>{children}</div>
);

const Glass = ({children, style = {}}: {children: React.ReactNode; style?: React.CSSProperties}) => (
  <div style={{background: colors.panel, border: '1px solid rgba(137, 198, 206, 0.28)', borderRadius: 22, boxShadow: '0 20px 60px rgba(0,0,0,0.35)', ...style}}>{children}</div>
);

const ProblemCard = ({label, detail, accent}: {label: string; detail: string; accent: string}) => (
  <Glass style={{padding: '28px 30px', width: 350, minHeight: 172}}>
    <div style={{width: 14, height: 14, borderRadius: 99, background: accent, boxShadow: `0 0 20px ${accent}`, marginBottom: 20}} />
    <div style={{fontSize: 26, fontWeight: 760, marginBottom: 12}}>{label}</div>
    <div style={{fontSize: 19, color: colors.muted, lineHeight: 1.35}}>{detail}</div>
  </Glass>
);

const Gameplay = ({from = 0, label}: {from?: number; label: string}) => (
  <AbsoluteFill>
    <Video src={staticFile('worldarena-gameplay.mp4')} startFrom={from} endAt={from + 450} muted style={{width: '100%', height: '100%', objectFit: 'cover'}} />
    <AbsoluteFill style={{background: 'linear-gradient(90deg, rgba(4,13,20,0.92) 0%, rgba(4,13,20,0.52) 32%, rgba(4,13,20,0.05) 72%)'}} />
    <div style={{position: 'absolute', left: 76, top: 70, background: 'rgba(3,12,18,0.82)', border: `1px solid ${colors.mint}`, borderRadius: 999, padding: '13px 20px', color: colors.mint, fontSize: 18, fontWeight: 740, letterSpacing: 2.4}}>{label}</div>
  </AbsoluteFill>
);

export const WorldArenaExplainer = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const introScale = spring({frame, fps, config: {damping: 16, mass: 0.75, stiffness: 100}});
  const section = (start: number) => Math.max(0, frame - start);

  return (
    <AbsoluteFill style={{background: colors.ink, color: colors.text, fontFamily: 'Inter, ui-sans-serif, system-ui, sans-serif', overflow: 'hidden'}}>
      <Video src={staticFile('worldarena-gameplay.mp4')} muted loop style={{width: '100%', height: '100%', objectFit: 'cover', opacity: 0.34}} />
      <AbsoluteFill style={{background: 'rgba(4, 14, 20, 0.48)'}} />
      <Sequence from={0} durationInFrames={360}>
        <Fade>
          <AbsoluteFill style={{background: 'radial-gradient(circle at 53% 40%, #1B4A57 0%, #0B202D 45%, #040A10 100%)', alignItems: 'center', justifyContent: 'center'}}>
            <div style={{textAlign: 'center', transform: `scale(${interpolate(introScale, [0, 1], [0.9, 1])})`}}>
              <Eyebrow>THE EMBODIED AI EVALUATION PROBLEM</Eyebrow>
              <div style={{fontSize: 118, fontWeight: 850, letterSpacing: -4, marginTop: 28}}>MODELS CAN TALK.</div>
              <div style={{fontSize: 118, fontWeight: 850, letterSpacing: -4, color: colors.mint}}>CAN THEY ACT?</div>
              <div style={{fontSize: 29, color: colors.muted, marginTop: 38}}>WorldArena tests intelligence through persistent decisions and consequences.</div>
            </div>
          </AbsoluteFill>
        </Fade>
      </Sequence>

      <Sequence from={330} durationInFrames={510}>
        <Fade>
          <AbsoluteFill style={{padding: '110px 120px', background: 'linear-gradient(135deg, #0B1D28 0%, #071018 100%)'}}>
            <Eyebrow>WHY CURRENT EVALS FALL SHORT</Eyebrow>
            <Headline>Most benchmarks grade what a model says in one turn.</Headline>
            <div style={{display: 'flex', gap: 28, marginTop: 65}}>
              <ProblemCard label="No consequences" detail="A fluent answer cannot fail physically." accent={colors.coral} />
              <ProblemCard label="No adaptation" detail="There is no winter, opponent, or supply crisis to respond to." accent={colors.gold} />
              <ProblemCard label="No social cost" detail="Promises, trades, and betrayals rarely change an outcome." accent={colors.blue} />
            </div>
          </AbsoluteFill>
        </Fade>
      </Sequence>

      <Sequence from={810} durationInFrames={510}>
        <Fade>
          <Gameplay from={0} label="THE CORE IDEA" />
          <div style={{position: 'absolute', left: 110, top: 260, width: 710}}>
            <Eyebrow>WORLD ARENA</Eyebrow>
            <Headline>The LLM is the strategist. The simulation is reality.</Headline>
            <div style={{fontSize: 26, lineHeight: 1.42, color: colors.muted, marginTop: 30}}>Agents choose high-level actions. Godot resolves movement, construction, resource use, combat, and territory control.</div>
          </div>
        </Fade>
      </Sequence>

      <Sequence from={1290} durationInFrames={540}>
        <Fade>
          <AbsoluteFill style={{padding: '92px 120px', background: 'radial-gradient(circle at 72% 48%, #183A3A 0%, #091923 58%, #040A10 100%)'}}>
            <Eyebrow>ONE SIMULTANEOUS ROUND</Eyebrow>
            <Headline>Every model plans before anyone sees the others’ move.</Headline>
            <div style={{display: 'flex', alignItems: 'center', gap: 18, marginTop: 70}}>
              {['Private observation', 'Sealed plan', 'World resolves', 'Receipts + memory'].map((item, index) => (
                <div key={item} style={{display: 'flex', alignItems: 'center', gap: 18}}>
                  <Glass style={{padding: '27px 20px', width: 260, textAlign: 'center'}}>
                    <div style={{color: colors.mint, fontSize: 17, fontWeight: 750, letterSpacing: 2}}>0{index + 1}</div>
                    <div style={{fontSize: 23, fontWeight: 760, marginTop: 12}}>{item}</div>
                  </Glass>
                  {index < 3 && <div style={{color: colors.gold, fontSize: 43}}>→</div>}
                </div>
              ))}
            </div>
            <div style={{fontSize: 24, color: colors.muted, marginTop: 54}}>Provider latency never determines initiative. Rendering never changes the outcome.</div>
          </AbsoluteFill>
        </Fade>
      </Sequence>

      <Sequence from={1800} durationInFrames={600}>
        <Fade>
          <Gameplay from={900} label="GAMEPLAY: BUILD · NEGOTIATE · FIGHT" />
          <div style={{position: 'absolute', left: 112, top: 260, width: 650}}>
            <Eyebrow>WHAT THE MATCH MAKES VISIBLE</Eyebrow>
            <Headline>Plans become a trail of evidence.</Headline>
            <div style={{fontSize: 25, color: colors.muted, lineHeight: 1.45, marginTop: 30}}>You can see workers gather, bases form, agents trade information, alliances shift, and supply lines decide a battle.</div>
          </div>
        </Fade>
      </Sequence>

      <Sequence from={2370} durationInFrames={570}>
        <Fade>
          <AbsoluteFill style={{padding: '98px 120px', background: 'linear-gradient(135deg, #07131C 0%, #102B38 100%)'}}>
            <Eyebrow>THE SCORE IS MORE THAN A WIN</Eyebrow>
            <Headline>WorldArena measures how a model wins — or fails.</Headline>
            <div style={{display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 22, marginTop: 56}}>
              {[
                ['Planning + adaptation', 'Prepared for threats, changed strategy after evidence.'],
                ['Resource + combat efficiency', 'Turned scarce materials into durable advantage.'],
                ['Social intelligence', 'Negotiated, traded, cooperated, or betrayed with consequence.'],
                ['Territory control', 'Captured and supplied valuable ground.'],
                ['Delegation + cognition', 'Used bounded advisors under a shared budget.'],
                ['Reliability', 'Submitted valid actions and handled failure safely.'],
              ].map(([title, detail]) => <ProblemCard key={title} label={title} detail={detail} accent={colors.mint} />)}
            </div>
          </AbsoluteFill>
        </Fade>
      </Sequence>

      <Sequence from={2910} durationInFrames={540}>
        <Fade>
          <Gameplay from={1800} label="DETERMINISTIC REPLAY · AUDITABLE OUTCOMES" />
          <div style={{position: 'absolute', left: 110, top: 250, width: 700}}>
            <Eyebrow>WHY IT MATTERS</Eyebrow>
            <Headline>Intelligence is not just an answer. It is a sequence of decisions under pressure.</Headline>
            <div style={{fontSize: 27, color: colors.muted, lineHeight: 1.42, marginTop: 30}}>WorldArena makes that sequence observable, repeatable, and comparable across models.</div>
          </div>
        </Fade>
      </Sequence>

      <Sequence from={3420} durationInFrames={180}>
        <Fade>
          <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center', background: 'radial-gradient(circle at center, #143744 0%, #07131C 58%, #04080C 100%)'}}>
            <div style={{textAlign: 'center'}}>
              <Eyebrow>WORLD ARENA</Eyebrow>
              <div style={{fontSize: 96, fontWeight: 850, marginTop: 20}}>EVALUATE WHAT AI DOES.</div>
              <div style={{fontSize: 30, color: colors.mint, marginTop: 28}}>Not only what it says.</div>
            </div>
          </AbsoluteFill>
        </Fade>
      </Sequence>
    </AbsoluteFill>
  );
};
