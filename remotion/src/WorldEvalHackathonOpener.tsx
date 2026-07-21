import {
  AbsoluteFill,
  Easing,
  Img,
  Sequence,
  interpolate,
  staticFile,
  useCurrentFrame,
} from 'remotion';

const FPS = 30;
const SLIDE_DURATION = 15 * FPS;

const colors = {
  ink: '#071018',
  panel: 'rgba(5, 13, 20, 0.88)',
  panelStrong: 'rgba(4, 10, 16, 0.96)',
  text: '#F8FBF7',
  muted: '#B6C5CC',
  cyan: '#54D9E8',
  mint: '#65E6BE',
  amber: '#FFC35C',
  coral: '#FF8278',
  purple: '#B9A1FF',
  green: '#4ADE80',
  line: 'rgba(190, 228, 235, 0.24)',
};

const ease = Easing.bezier(0.16, 1, 0.3, 1);

const reveal = (frame: number, delay = 0, duration = 22) =>
  interpolate(frame, [delay, delay + duration], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: ease,
  });

const rise = (frame: number, delay = 0, distance = 34) =>
  interpolate(frame, [delay, delay + 24], [distance, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: ease,
  });

const sceneOpacity = (frame: number, duration: number) =>
  interpolate(frame, [0, duration], [1, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

const Brand = ({section, slide}: {section: string; slide: string}) => (
  <>
    <div
      style={{
        position: 'absolute',
        zIndex: 50,
        top: 42,
        left: 64,
        right: 64,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        color: colors.text,
        fontFamily: 'Arial, Helvetica, sans-serif',
        fontSize: 20,
        fontWeight: 800,
        letterSpacing: 1.8,
        textShadow: '0 4px 24px rgba(0,0,0,0.72)',
      }}
    >
      <div style={{display: 'flex', gap: 18, alignItems: 'center'}}>
        <span>WORLDEVAL</span>
        <span style={{height: 22, width: 1, background: colors.line}} />
        <span style={{color: colors.muted, fontWeight: 650}}>{section}</span>
      </div>
      <div style={{display: 'flex', alignItems: 'center', gap: 20}}>
        <span style={{color: colors.muted}}>OPENAI BUILD WEEK</span>
        <span style={{color: colors.cyan}}>{slide}</span>
      </div>
    </div>
    <div
      style={{
        position: 'absolute',
        zIndex: 50,
        left: 64,
        right: 64,
        bottom: 34,
        height: 2,
        borderRadius: 999,
        background: 'rgba(255,255,255,0.18)',
      }}
    />
  </>
);

const WipeIn = ({accent}: {accent: string}) => {
  const frame = useCurrentFrame();
  return (
    <div
      style={{
        position: 'absolute',
        zIndex: 90,
        inset: 0,
        background: accent,
        translate: `${interpolate(frame, [0, 22], [0, -104], {
          extrapolateRight: 'clamp',
          easing: ease,
        })}% 0`,
      }}
    />
  );
};

const Vignette = ({strength = 0.75}: {strength?: number}) => (
  <AbsoluteFill
    style={{
      background: `radial-gradient(circle at 50% 42%, transparent 24%, rgba(1, 6, 10, ${strength}) 100%)`,
    }}
  />
);

const Eyebrow = ({children, color}: {children: React.ReactNode; color: string}) => (
  <div
    style={{
      color,
      fontSize: 20,
      fontWeight: 900,
      letterSpacing: 4.8,
      marginBottom: 20,
    }}
  >
    {children}
  </div>
);

const HookSlide = ({duration}: {duration: number}) => {
  const frame = useCurrentFrame();
  const panels = [
    {src: 'opener-labyrinth-overview.png', delay: 0},
    {src: 'opener-rts-bridge.jpg', delay: 6},
    {src: 'opener-conquest-overview.png', delay: 12},
  ];

  return (
    <AbsoluteFill
      style={{
        background: colors.ink,
        color: colors.text,
        fontFamily: 'Arial, Helvetica, sans-serif',
        opacity: sceneOpacity(frame, duration),
      }}
    >
      <div style={{display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', height: '100%'}}>
        {panels.map((panel, index) => (
          <div
            key={panel.src}
            style={{
              position: 'relative',
              overflow: 'hidden',
              opacity: reveal(frame, panel.delay, 20),
              translate: `0 ${rise(frame, panel.delay, 72)}px`,
              borderRight: index < panels.length - 1 ? `2px solid ${colors.ink}` : undefined,
            }}
          >
            <Img
              src={staticFile(panel.src)}
              style={{
                width: '100%',
                height: '100%',
                objectFit: 'cover',
                scale: interpolate(frame, [0, duration], [1.08, 1.14]),
                filter: 'saturate(0.84) brightness(0.66)',
              }}
            />
          </div>
        ))}
      </div>
      <AbsoluteFill style={{background: 'rgba(3,8,12,0.34)'}} />
      <Vignette strength={0.84} />
      <Brand section="THE QUESTION" slide="01 / 04" />

      <div
        style={{
          position: 'absolute',
          left: 92,
          right: 92,
          top: 238,
          zIndex: 20,
          textAlign: 'center',
          opacity: reveal(frame, 22),
          translate: `0 ${rise(frame, 22, 38)}px`,
        }}
      >
        <div style={{color: colors.cyan, fontSize: 22, fontWeight: 900, letterSpacing: 6}}>
          WORLDEVAL
        </div>
        <div
          style={{
            marginTop: 24,
            fontSize: 104,
            lineHeight: 0.99,
            fontWeight: 900,
            letterSpacing: -4.5,
            textShadow: '0 16px 60px rgba(0,0,0,0.72)',
          }}
        >
          Models can answer.
          <br />
          <span style={{color: colors.mint}}>Can they act?</span>
        </div>
        <div
          style={{
            marginTop: 36,
            color: colors.text,
            fontSize: 30,
            lineHeight: 1.35,
            fontWeight: 650,
            opacity: reveal(frame, 126, 28),
            translate: `0 ${rise(frame, 126, 20)}px`,
            textShadow: '0 8px 34px rgba(0,0,0,0.8)',
          }}
        >
          Evaluate what an LLM <span style={{color: colors.amber}}>does</span> — not only what it says.
        </div>
        <div
          style={{
            marginTop: 26,
            display: 'flex',
            justifyContent: 'center',
            gap: 14,
            opacity: reveal(frame, 172, 24),
          }}
        >
          {['INTERACTIVE', 'DETERMINISTIC', 'AUDITABLE'].map((label) => (
            <div
              key={label}
              style={{
                borderRadius: 999,
                border: `1px solid ${colors.line}`,
                background: 'rgba(2,8,12,0.72)',
                padding: '11px 18px',
                color: colors.muted,
                fontSize: 17,
                fontWeight: 850,
                letterSpacing: 1.8,
              }}
            >
              {label}
            </div>
          ))}
        </div>
      </div>
      <WipeIn accent={colors.cyan} />
    </AbsoluteFill>
  );
};

const ComparisonColumn = ({
  heading,
  accent,
  items,
  frame,
  delay,
}: {
  heading: string;
  accent: string;
  items: string[];
  frame: number;
  delay: number;
}) => (
  <div
    style={{
      flex: 1,
      minHeight: 390,
      borderRadius: 28,
      border: `1px solid ${accent}77`,
      background: colors.panel,
      padding: '31px 34px',
      boxShadow: '0 30px 90px rgba(0,0,0,0.35)',
      opacity: reveal(frame, delay, 25),
      translate: `0 ${rise(frame, delay, 36)}px`,
    }}
  >
    <div style={{color: accent, fontSize: 24, fontWeight: 900, letterSpacing: 2.6}}>{heading}</div>
    <div style={{height: 1, background: colors.line, margin: '23px 0 10px'}} />
    {items.map((item, index) => (
      <div
        key={item}
        style={{
          display: 'flex',
          gap: 17,
          alignItems: 'center',
          padding: '17px 0',
          opacity: reveal(frame, delay + 22 + index * 12, 20),
        }}
      >
        <div
          style={{
            flex: '0 0 auto',
            width: 10,
            height: 10,
            borderRadius: 999,
            background: accent,
            boxShadow: `0 0 22px ${accent}`,
          }}
        />
        <div style={{fontSize: 27, lineHeight: 1.28, fontWeight: 700}}>{item}</div>
      </div>
    ))}
  </div>
);

const GapSlide = ({duration}: {duration: number}) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill
      style={{
        background: colors.ink,
        color: colors.text,
        fontFamily: 'Arial, Helvetica, sans-serif',
        opacity: sceneOpacity(frame, duration),
      }}
    >
      <Img
        src={staticFile('portal-run.png')}
        style={{
          width: '100%',
          height: '100%',
          objectFit: 'cover',
          scale: interpolate(frame, [0, duration], [1.05, 1.1]),
          filter: 'brightness(0.24) saturate(0.55) blur(2px)',
        }}
      />
      <AbsoluteFill style={{background: 'linear-gradient(115deg, rgba(3,8,12,0.98), rgba(3,8,12,0.72))'}} />
      <Brand section="WHY IT EXISTS" slide="02 / 04" />

      <div style={{position: 'absolute', zIndex: 20, left: 82, right: 82, top: 132}}>
        <div style={{opacity: reveal(frame, 22), translate: `0 ${rise(frame, 22, 26)}px`}}>
          <Eyebrow color={colors.amber}>THE EVALUATION GAP</Eyebrow>
          <div style={{fontSize: 63, lineHeight: 1.04, fontWeight: 900, letterSpacing: -2.5}}>
            An answer is a moment.
            <span style={{color: colors.amber}}> Agency is a trajectory.</span>
          </div>
        </div>

        <div style={{display: 'flex', gap: 24, marginTop: 36}}>
          <ComparisonColumn
            heading="STATIC EVALUATION"
            accent={colors.muted}
            frame={frame}
            delay={65}
            items={['One prompt and one response', 'Scores the final output', 'Ends before consequences unfold']}
          />
          <ComparisonColumn
            heading="WORLDEVAL"
            accent={colors.mint}
            frame={frame}
            delay={82}
            items={['Partial observations over time', 'Repeated decisions under a budget', 'Plans meet persistent consequences']}
          />
        </div>

        <div
          style={{
            marginTop: 27,
            color: colors.muted,
            fontSize: 22,
            fontWeight: 800,
            letterSpacing: 1.6,
            opacity: reveal(frame, 185, 24),
          }}
        >
          PLANNING&nbsp;&nbsp;·&nbsp;&nbsp;ADAPTATION&nbsp;&nbsp;·&nbsp;&nbsp;RESOURCE DISCIPLINE&nbsp;&nbsp;·&nbsp;&nbsp;COORDINATION&nbsp;&nbsp;·&nbsp;&nbsp;RELIABILITY
        </div>
      </div>
      <WipeIn accent={colors.amber} />
    </AbsoluteFill>
  );
};

const PipelineCard = ({
  number,
  title,
  copy,
  color,
  frame,
  delay,
}: {
  number: string;
  title: string;
  copy: string;
  color: string;
  frame: number;
  delay: number;
}) => (
  <div
    style={{
      flex: 1,
      minHeight: 280,
      borderRadius: 25,
      border: `1px solid ${color}77`,
      background: colors.panelStrong,
      padding: '28px 28px 30px',
      opacity: reveal(frame, delay, 24),
      translate: `0 ${rise(frame, delay, 32)}px`,
      boxShadow: '0 28px 70px rgba(0,0,0,0.38)',
    }}
  >
    <div style={{color, fontSize: 18, fontWeight: 900, letterSpacing: 2.4}}>{number}</div>
    <div style={{fontSize: 31, fontWeight: 900, marginTop: 20}}>{title}</div>
    <div style={{color: colors.muted, fontSize: 22, lineHeight: 1.4, marginTop: 15, fontWeight: 600}}>
      {copy}
    </div>
  </div>
);

const MethodSlide = ({duration}: {duration: number}) => {
  const frame = useCurrentFrame();
  const steps = [
    ['01', 'OBSERVE', 'The agent receives only its participant-visible state.', colors.cyan],
    ['02', 'DECIDE', 'The LLM returns a bounded, structured JSON action.', colors.amber],
    ['03', 'RESOLVE', 'Godot applies movement, resources, combat, and world rules.', colors.coral],
    ['04', 'RECORD', 'Events, receipts, usage, hashes, and replay are preserved.', colors.purple],
  ] as const;

  return (
    <AbsoluteFill
      style={{
        background: colors.ink,
        color: colors.text,
        fontFamily: 'Arial, Helvetica, sans-serif',
        opacity: sceneOpacity(frame, duration),
      }}
    >
      <Img
        src={staticFile('opener-conquest-overview.png')}
        style={{
          position: 'absolute',
          inset: 0,
          width: '100%',
          height: '100%',
          objectFit: 'cover',
          scale: interpolate(frame, [0, duration], [1.05, 1.11]),
          filter: 'brightness(0.2) saturate(0.5) blur(2px)',
        }}
      />
      <AbsoluteFill style={{background: 'linear-gradient(180deg, rgba(3,8,12,0.96), rgba(3,8,12,0.76))'}} />
      <Brand section="HOW IT WORKS" slide="03 / 04" />

      <div style={{position: 'absolute', zIndex: 20, left: 76, right: 76, top: 128}}>
        <div style={{opacity: reveal(frame, 22), translate: `0 ${rise(frame, 22, 26)}px`}}>
          <Eyebrow color={colors.cyan}>THE AGENT PLANS · THE WORLD DECIDES</Eyebrow>
          <div style={{fontSize: 64, lineHeight: 1.04, fontWeight: 900, letterSpacing: -2.5}}>
            Every model call becomes a <span style={{color: colors.mint}}>world consequence.</span>
          </div>
        </div>

        <div style={{display: 'flex', gap: 16, marginTop: 43}}>
          {steps.map(([number, title, copy, color], index) => (
            <PipelineCard
              key={title}
              number={number}
              title={title}
              copy={copy}
              color={color}
              frame={frame}
              delay={66 + index * 22}
            />
          ))}
        </div>

        <div
          style={{
            marginTop: 31,
            borderRadius: 18,
            border: `1px solid ${colors.mint}66`,
            background: 'rgba(7, 28, 27, 0.88)',
            padding: '18px 24px',
            color: colors.text,
            fontSize: 24,
            lineHeight: 1.35,
            fontWeight: 700,
            opacity: reveal(frame, 176, 24),
          }}
        >
          <span style={{color: colors.mint, fontWeight: 900}}>Clear separation:</span> the LLM chooses strategy; it never controls coordinates, physics, damage, resources, or scoring.
        </div>
      </div>
      <WipeIn accent={colors.cyan} />
    </AbsoluteFill>
  );
};

const EvidenceRow = ({
  label,
  copy,
  color,
  frame,
  delay,
}: {
  label: string;
  copy: string;
  color: string;
  frame: number;
  delay: number;
}) => (
  <div
    style={{
      display: 'grid',
      gridTemplateColumns: '235px 1fr',
      gap: 22,
      alignItems: 'center',
      padding: '18px 21px',
      borderRadius: 18,
      border: `1px solid ${color}55`,
      background: 'rgba(3, 10, 15, 0.82)',
      opacity: reveal(frame, delay, 22),
      translate: `0 ${rise(frame, delay, 24)}px`,
    }}
  >
    <div style={{color, fontSize: 19, fontWeight: 900, letterSpacing: 1.7}}>{label}</div>
    <div style={{fontSize: 22, lineHeight: 1.35, color: colors.text, fontWeight: 650}}>{copy}</div>
  </div>
);

const EvidenceSlide = ({duration}: {duration: number}) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill
      style={{
        background: colors.ink,
        color: colors.text,
        fontFamily: 'Arial, Helvetica, sans-serif',
        opacity: sceneOpacity(frame, duration),
      }}
    >
      <Img
        src={staticFile('opener-evidence-podium.png')}
        style={{
          position: 'absolute',
          right: -120,
          top: 0,
          width: '74%',
          height: '100%',
          objectFit: 'cover',
          objectPosition: 'center',
          scale: interpolate(frame, [0, duration], [1.02, 1.07]),
          filter: 'brightness(0.64) saturate(0.9)',
        }}
      />
      <AbsoluteFill style={{background: 'linear-gradient(90deg, #071018 0%, #071018 44%, rgba(7,16,24,0.82) 60%, rgba(7,16,24,0.17) 100%)'}} />
      <Brand section="WHAT IT PRODUCES" slide="04 / 04" />

      <div
        style={{
          position: 'absolute',
          zIndex: 20,
          left: 76,
          top: 135,
          width: 1020,
        }}
      >
        <div style={{opacity: reveal(frame, 22), translate: `0 ${rise(frame, 22, 26)}px`}}>
          <Eyebrow color={colors.green}>AUDITABLE EVALUATION</Eyebrow>
          <div style={{fontSize: 67, lineHeight: 1.03, fontWeight: 900, letterSpacing: -2.7}}>
            Behaviour becomes <span style={{color: colors.green}}>evidence.</span>
          </div>
        </div>

        <div style={{display: 'grid', gap: 12, marginTop: 35}}>
          <EvidenceRow
            label="COMPETITIVE RESULT"
            copy="Godot-derived placement from the authoritative world."
            color={colors.amber}
            frame={frame}
            delay={64}
          />
          <EvidenceRow
            label="WORLDEVAL SCORE"
            copy="Versioned behavioural categories linked to actions and events."
            color={colors.green}
            frame={frame}
            delay={87}
          />
          <EvidenceRow
            label="AUDIT TRAIL"
            copy="Typed calls, receipts, usage, state hashes, and replay."
            color={colors.purple}
            frame={frame}
            delay={110}
          />
        </div>

        <div
          style={{
            marginTop: 23,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            gap: 22,
            opacity: reveal(frame, 154, 22),
          }}
        >
          <div style={{color: colors.mint, fontSize: 25, fontWeight: 900, letterSpacing: 1.2}}>
            NO LLM JUDGE
          </div>
          <div style={{color: colors.muted, fontSize: 21, fontWeight: 700}}>
            Claims can be reproduced and inspected.
          </div>
        </div>

        <div
          style={{
            marginTop: 25,
            display: 'inline-flex',
            alignItems: 'center',
            gap: 18,
            borderRadius: 17,
            padding: '17px 23px',
            background: colors.cyan,
            color: colors.ink,
            fontSize: 23,
            fontWeight: 900,
            boxShadow: `0 20px 60px ${colors.cyan}44`,
            opacity: reveal(frame, 292, 25),
            translate: `0 ${rise(frame, 292, 24)}px`,
          }}
        >
          NOW, LET’S SEE IT LIVE
          <span style={{fontSize: 29}}>→</span>
          <span style={{fontSize: 19}}>lab.openai-buildweek.lissan.dev</span>
        </div>
      </div>
      <WipeIn accent={colors.green} />
    </AbsoluteFill>
  );
};

const scenes = {
  hook: SLIDE_DURATION,
  gap: SLIDE_DURATION,
  method: SLIDE_DURATION,
  evidence: SLIDE_DURATION,
};

export const WORLD_EVAL_HACKATHON_OPENER_DURATION = Object.values(scenes).reduce(
  (sum, value) => sum + value,
  0,
);

export const WorldEvalHackathonOpener = () => {
  let cursor = 0;
  const sequence = (duration: number, name: string, content: React.ReactNode) => {
    const from = cursor;
    cursor += duration;
    return (
      <Sequence key={name} name={name} from={from} durationInFrames={duration} premountFor={FPS}>
        {content}
      </Sequence>
    );
  };

  return (
    <AbsoluteFill style={{background: colors.ink}}>
      {sequence(scenes.hook, '01 — Models can answer. Can they act?', <HookSlide duration={scenes.hook} />)}
      {sequence(scenes.gap, '02 — The evaluation gap', <GapSlide duration={scenes.gap} />)}
      {sequence(scenes.method, '03 — How WorldEval works', <MethodSlide duration={scenes.method} />)}
      {sequence(scenes.evidence, '04 — Behaviour becomes evidence', <EvidenceSlide duration={scenes.evidence} />)}
    </AbsoluteFill>
  );
};
