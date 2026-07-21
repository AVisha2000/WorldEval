import {Video} from '@remotion/media';
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

const palette = {
  bg: '#05090D',
  panel: 'rgba(5, 13, 20, 0.88)',
  panelStrong: 'rgba(4, 10, 16, 0.96)',
  line: 'rgba(148, 196, 210, 0.26)',
  text: '#F5F7F4',
  muted: '#AFC0C8',
  cyan: '#58D8E8',
  mint: '#63E6BE',
  amber: '#FFBF58',
  purple: '#B89CFF',
  coral: '#FF8178',
  green: '#34D399',
};

const fade = (frame: number, duration = 14) =>
  interpolate(frame, [0, duration], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.bezier(0.16, 1, 0.3, 1),
  });

const rise = (frame: number, delay = 0) =>
  interpolate(frame, [delay, delay + 18], [28, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.bezier(0.16, 1, 0.3, 1),
  });

const Brand = ({section}: {section: string}) => (
  <>
    <div
      style={{
        position: 'absolute',
        left: 58,
        top: 42,
        zIndex: 20,
        display: 'flex',
        alignItems: 'center',
        gap: 18,
        fontSize: 20,
        fontWeight: 800,
        letterSpacing: 1.4,
      }}
    >
      <span style={{color: palette.text}}>WORLDEVAL</span>
      <span style={{height: 22, width: 1, background: palette.line}} />
      <span style={{color: palette.muted, fontWeight: 650}}>{section}</span>
    </div>
    <div
      style={{
        position: 'absolute',
        left: 58,
        right: 58,
        bottom: 34,
        zIndex: 20,
        height: 2,
        borderRadius: 99,
        background: 'rgba(255,255,255,0.12)',
      }}
    />
  </>
);

const GameplayVideo = ({
  src,
  trimBefore,
  playbackRate = 1,
  darken = 0,
  objectFit = 'cover',
}: {
  src: string;
  trimBefore: number;
  playbackRate?: number;
  darken?: number;
  objectFit?: 'cover' | 'contain';
}) => (
  <AbsoluteFill style={{backgroundColor: palette.bg}}>
    <Video
      muted
      playbackRate={playbackRate}
      src={staticFile(src)}
      trimBefore={trimBefore}
      style={{height: '100%', width: '100%', objectFit}}
    />
    {darken > 0 ? (
      <AbsoluteFill style={{background: `rgba(2, 8, 12, ${darken})`}} />
    ) : null}
  </AbsoluteFill>
);

const SceneTitle = ({
  eyebrow,
  title,
  copy,
  accent = palette.mint,
  width = 900,
}: {
  eyebrow: string;
  title: string;
  copy?: string;
  accent?: string;
  width?: number;
}) => {
  const frame = useCurrentFrame();
  return (
    <div
      style={{
        position: 'absolute',
        left: 76,
        top: 210,
        zIndex: 10,
        width,
        opacity: fade(frame),
        translate: `0 ${rise(frame)}px`,
      }}
    >
      <div
        style={{
          color: accent,
          fontSize: 20,
          fontWeight: 800,
          letterSpacing: 4.5,
          marginBottom: 22,
        }}
      >
        {eyebrow}
      </div>
      <div
        style={{
          color: palette.text,
          fontSize: 74,
          lineHeight: 1.04,
          fontWeight: 850,
          letterSpacing: -2.4,
          textShadow: '0 8px 34px rgba(0,0,0,0.5)',
        }}
      >
        {title}
      </div>
      {copy ? (
        <div
          style={{
            marginTop: 26,
            maxWidth: 790,
            color: palette.muted,
            fontSize: 27,
            lineHeight: 1.42,
            fontWeight: 520,
          }}
        >
          {copy}
        </div>
      ) : null}
    </div>
  );
};

const GameLabel = ({
  index,
  title,
  capability,
  accent,
  speed,
}: {
  index: string;
  title: string;
  capability: string;
  accent: string;
  speed: string;
}) => {
  const frame = useCurrentFrame();
  return (
    <div
      style={{
        position: 'absolute',
        left: 58,
        top: 184,
        zIndex: 20,
        display: 'flex',
        alignItems: 'center',
        gap: 18,
        padding: '12px 16px 12px 12px',
        borderRadius: 22,
        border: `1px solid ${palette.line}`,
        background: palette.panel,
        boxShadow: '0 18px 55px rgba(0,0,0,0.3)',
        opacity: fade(frame),
        translate: `${rise(frame)}px 0`,
      }}
    >
      <div
        style={{
          width: 62,
          height: 62,
          borderRadius: 18,
          display: 'grid',
          placeItems: 'center',
          color: palette.bg,
          background: accent,
          fontSize: 22,
          fontWeight: 900,
        }}
      >
        {index}
      </div>
      <div>
        <div style={{fontSize: 30, fontWeight: 850}}>{title}</div>
        <div style={{marginTop: 4, color: palette.muted, fontSize: 18}}>
          {capability}
        </div>
      </div>
      <div
        style={{
          marginLeft: 12,
          padding: '9px 14px',
          borderRadius: 999,
          border: `1px solid ${accent}`,
          color: accent,
          background: 'rgba(3,9,14,0.74)',
          fontSize: 16,
          fontWeight: 800,
        }}
      >
        {speed}
      </div>
    </div>
  );
};

type AgentCallProps = {
  accent: string;
  observed: string;
  action: string;
  receipt: string;
  title?: string;
};

const AgentCall = ({
  accent,
  observed,
  action,
  receipt,
  title = 'AGENT DECISION CALL',
}: AgentCallProps) => {
  const frame = useCurrentFrame();
  const reveal = fade(frame, 10);
  const actionProgress = interpolate(frame, [20, 42], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const receiptProgress = interpolate(frame, [48, 72], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  return (
    <div
      style={{
        position: 'absolute',
        zIndex: 30,
        right: 62,
        bottom: 68,
        width: 680,
        borderRadius: 24,
        overflow: 'hidden',
        border: `1px solid ${accent}88`,
        background: palette.panelStrong,
        boxShadow: '0 30px 80px rgba(0,0,0,0.54)',
        opacity: reveal,
        translate: `${interpolate(frame, [0, 14], [45, 0], {
          extrapolateRight: 'clamp',
        })}px 0`,
      }}
    >
      <div
        style={{
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
          padding: '17px 22px',
          borderBottom: `1px solid ${palette.line}`,
        }}
      >
        <div style={{display: 'flex', alignItems: 'center', gap: 12}}>
          <div
            style={{
              width: 11,
              height: 11,
              borderRadius: 99,
              background: accent,
              boxShadow: `0 0 18px ${accent}`,
              scale: interpolate(frame % 30, [0, 15, 29], [0.8, 1.2, 0.8]),
            }}
          />
          <span style={{fontSize: 17, fontWeight: 900, letterSpacing: 2.2}}>
            {title}
          </span>
        </div>
        <span style={{color: palette.muted, fontSize: 14}}>
          Demo provider · live-provider contract
        </span>
      </div>
      <div style={{display: 'grid', gridTemplateColumns: '148px 1fr'}}>
        <div style={{padding: '17px 20px', color: palette.muted, fontSize: 14, fontWeight: 800}}>
          OBSERVED
        </div>
        <div style={{padding: '17px 20px', fontSize: 19, lineHeight: 1.35}}>{observed}</div>
        <div
          style={{
            padding: '17px 20px',
            borderTop: `1px solid ${palette.line}`,
            color: accent,
            fontSize: 14,
            fontWeight: 850,
          }}
        >
          RETURNED
        </div>
        <div
          style={{
            padding: '17px 20px',
            borderTop: `1px solid ${palette.line}`,
            color: palette.text,
            fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
            fontSize: 15,
            lineHeight: 1.4,
            opacity: actionProgress,
            overflowWrap: 'anywhere',
          }}
        >
          {action}
        </div>
        <div
          style={{
            padding: '16px 20px',
            borderTop: `1px solid ${palette.line}`,
            color: palette.green,
            fontSize: 14,
            fontWeight: 850,
          }}
        >
          RECEIPT
        </div>
        <div
          style={{
            padding: '16px 20px',
            borderTop: `1px solid ${palette.line}`,
            color: palette.muted,
            fontSize: 18,
            opacity: receiptProgress,
          }}
        >
          ✓ {receipt}
        </div>
      </div>
    </div>
  );
};

const VerificationRibbon = () => (
  <div
    style={{
      position: 'absolute',
      left: '50%',
      top: 48,
      zIndex: 24,
      width: 700,
      marginLeft: -350,
      padding: '13px 20px',
      borderRadius: 14,
      border: `1px solid ${palette.green}77`,
      background: 'rgba(3, 9, 14, 0.96)',
      color: palette.green,
      textAlign: 'center',
      fontSize: 15,
      fontWeight: 850,
      letterSpacing: 2.2,
    }}
  >
    VERIFIED AUTHORITY REPLAY · FIXED SEED 424242
  </div>
);

const ScorePanel = ({
  accent,
  title,
  winner,
  metrics,
  note = 'Authority-derived result · replay verified',
}: {
  accent: string;
  title: string;
  winner: string;
  metrics: Array<[string, string]>;
  note?: string;
}) => {
  const frame = useCurrentFrame();
  return (
    <div
      style={{
        position: 'absolute',
        inset: 'auto 70px 66px auto',
        zIndex: 35,
        width: 700,
        borderRadius: 26,
        padding: '28px 30px 24px',
        background: palette.panelStrong,
        border: `1px solid ${accent}88`,
        boxShadow: '0 34px 90px rgba(0,0,0,0.58)',
        opacity: fade(frame),
        translate: `0 ${rise(frame)}px`,
      }}
    >
      <div style={{color: accent, fontSize: 15, fontWeight: 850, letterSpacing: 3.4}}>
        {title}
      </div>
      <div style={{fontSize: 46, fontWeight: 900, marginTop: 11}}>{winner}</div>
      <div style={{display: 'grid', gridTemplateColumns: `repeat(${metrics.length}, 1fr)`, gap: 12, marginTop: 22}}>
        {metrics.map(([value, label]) => (
          <div key={label} style={{borderTop: `1px solid ${palette.line}`, paddingTop: 15}}>
            <div style={{fontSize: 27, fontWeight: 850}}>{value}</div>
            <div style={{fontSize: 14, color: palette.muted, marginTop: 5}}>{label}</div>
          </div>
        ))}
      </div>
      <div style={{fontSize: 14, color: palette.green, marginTop: 20}}>✓ {note}</div>
    </div>
  );
};

const ColdOpen = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{background: palette.bg, color: palette.text}}>
      <Sequence from={0} durationInFrames={60}>
        <GameplayVideo src="labyrinth-run.mp4" trimBefore={20 * FPS} playbackRate={2.2} />
      </Sequence>
      <Sequence from={60} durationInFrames={60}>
        <GameplayVideo src="rts-skirmish.mp4" trimBefore={80 * FPS} playbackRate={2.2} />
      </Sequence>
      <Sequence from={120} durationInFrames={60}>
        <GameplayVideo src="crossroads-highlight.mp4" trimBefore={51 * FPS} playbackRate={2.5} />
      </Sequence>
      <Sequence from={180} durationInFrames={60}>
        <GameplayVideo src="solo-construction.mp4" trimBefore={100 * FPS} playbackRate={2.2} />
      </Sequence>
      <AbsoluteFill style={{background: 'linear-gradient(90deg, rgba(2,7,10,0.86), rgba(2,7,10,0.08) 72%)'}} />
      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          top: 0,
          height: 88,
          background: 'rgba(3,9,14,0.94)',
          borderBottom: `1px solid ${palette.line}`,
        }}
      />
      <div
        style={{
          position: 'absolute',
          left: 70,
          top: 355,
          width: 1170,
          opacity: fade(frame, 8),
        }}
      >
        <div style={{fontSize: 94, lineHeight: 1.02, fontWeight: 900, letterSpacing: -3.6}}>
          MODELS CAN TALK.
        </div>
        <div style={{fontSize: 94, lineHeight: 1.02, fontWeight: 900, letterSpacing: -3.6, color: palette.mint}}>
          CAN THEY ACT?
        </div>
      </div>
      <div
        style={{
          position: 'absolute',
          right: 58,
          top: 54,
          padding: '12px 17px',
          border: `1px solid ${palette.line}`,
          background: palette.panel,
          borderRadius: 999,
          fontSize: 16,
          fontWeight: 800,
        }}
      >
        GAMEPLAY HIGHLIGHTS · 2–3×
      </div>
    </AbsoluteFill>
  );
};

const Introduction = () => (
  <AbsoluteFill style={{background: palette.bg, color: palette.text}}>
    <GameplayVideo src="crossroads-highlight.mp4" trimBefore={0} playbackRate={1.65} darken={0.58} />
    <AbsoluteFill style={{background: 'linear-gradient(90deg, rgba(2,8,12,0.96) 0%, rgba(2,8,12,0.75) 46%, rgba(2,8,12,0.08) 100%)'}} />
    <Brand section="WHY IT EXISTS" />
    <VerificationRibbon />
    <SceneTitle
      eyebrow="WORLD EVAL"
      title="Evaluate what AI does. Not only what it says."
      copy="WorldEval measures intelligent agents inside interactive, deterministic worlds. WorldArena is its first 3D environment."
      accent={palette.amber}
      width={1050}
    />
  </AbsoluteFill>
);

const CallPipeline = () => {
  const frame = useCurrentFrame();
  const steps = [
    ['01', 'OBSERVE', 'Participant-visible state'],
    ['02', 'CALL', 'Structured agent decision'],
    ['03', 'RESOLVE', 'Godot applies world rules'],
    ['04', 'EVIDENCE', 'Receipt, score, replay'],
  ] as const;
  return (
    <AbsoluteFill style={{background: palette.bg, color: palette.text}}>
      <GameplayVideo src="solo-construction.mp4" trimBefore={8 * FPS} playbackRate={1.8} darken={0.68} />
      <Brand section="HOW IT WORKS" />
      <div style={{position: 'absolute', left: 76, top: 170, right: 76, zIndex: 15}}>
        <div style={{color: palette.mint, fontSize: 18, fontWeight: 850, letterSpacing: 4}}>
          THE AGENT PLANS · THE WORLD DECIDES
        </div>
        <div style={{fontSize: 59, fontWeight: 880, marginTop: 16, letterSpacing: -1.5}}>
          Every call becomes a visible consequence.
        </div>
        <div style={{display: 'flex', gap: 14, marginTop: 42}}>
          {steps.map(([number, label, copy], index) => {
            const visibility = interpolate(frame, [index * 18, index * 18 + 18], [0, 1], {
              extrapolateLeft: 'clamp',
              extrapolateRight: 'clamp',
            });
            return (
              <div
                key={label}
                style={{
                  flex: 1,
                  minHeight: 150,
                  borderRadius: 20,
                  padding: '22px 22px',
                  border: `1px solid ${palette.line}`,
                  background: palette.panel,
                  opacity: visibility,
                  translate: `0 ${interpolate(visibility, [0, 1], [25, 0])}px`,
                }}
              >
                <div style={{color: palette.amber, fontSize: 15, fontWeight: 850}}>{number}</div>
                <div style={{fontSize: 25, fontWeight: 850, marginTop: 12}}>{label}</div>
                <div style={{color: palette.muted, fontSize: 17, lineHeight: 1.35, marginTop: 9}}>{copy}</div>
              </div>
            );
          })}
        </div>
      </div>
      <Sequence from={210} durationInFrames={270}>
        <AgentCall
          accent={palette.cyan}
          observed="Resource ahead · front · near · gatherable"
          action={'{"intent":"approach_resource","move_y":1000,"duration_ticks":20}'}
          receipt="accepted · distance moved 4,000 mt"
          title="CONTROLLER CALL"
        />
      </Sequence>
    </AbsoluteFill>
  );
};

const LabyrinthScene = () => (
  <AbsoluteFill style={{background: palette.bg, color: palette.text}}>
    <GameplayVideo src="labyrinth-run.mp4" trimBefore={0} playbackRate={3} />
    <AbsoluteFill style={{background: 'linear-gradient(180deg, rgba(3,8,12,0.48), transparent 28%, transparent 70%, rgba(3,8,12,0.45))'}} />
    <GameLabel index="01" title="Labyrinth Run" capability="Spatial reasoning · recovery · path efficiency" accent={palette.amber} speed="3× PLAYBACK" />
    <Sequence from={135} durationInFrames={260}>
      <AgentCall
        accent={palette.amber}
        observed="Junction visible · right and forward passages"
        action={'{"task":"try_right_passage","memory":"avoid exhausted branch"}'}
        receipt="choice accepted · route state updated"
      />
    </Sequence>
    <Sequence from={500} durationInFrames={160}>
      <ScorePanel
        accent={palette.amber}
        title="SPATIAL-REASONING RESULT"
        winner="Sol wins in 44.8 seconds"
        metrics={[
          ['93.75%', 'path efficiency'],
          ['1', 'dead end'],
          ['64', 'cells travelled'],
        ]}
      />
    </Sequence>
  </AbsoluteFill>
);

const RtsScene = () => (
  <AbsoluteFill style={{background: palette.bg, color: palette.text}}>
    <Sequence from={0} durationInFrames={210}>
      <GameplayVideo src="rts-skirmish.mp4" trimBefore={8 * FPS} playbackRate={3.2} />
    </Sequence>
    <Sequence from={210} durationInFrames={180}>
      <GameplayVideo src="rts-skirmish.mp4" trimBefore={54 * FPS} playbackRate={3.1} />
    </Sequence>
    <Sequence from={390} durationInFrames={240}>
      <GameplayVideo src="rts-skirmish.mp4" trimBefore={78 * FPS} playbackRate={3.15} />
    </Sequence>
    <Sequence from={630} durationInFrames={210}>
      <GameplayVideo src="rts-skirmish.mp4" trimBefore={125 * FPS} playbackRate={3.4} />
    </Sequence>
    <AbsoluteFill style={{background: 'linear-gradient(180deg, rgba(3,8,12,0.48), transparent 30%, transparent 74%, rgba(3,8,12,0.48))'}} />
    <GameLabel index="02" title="Mini RTS" capability="Economy · build order · combat timing" accent={palette.cyan} speed="3.2× PLAYBACK" />
    <Sequence from={105} durationInFrames={220}>
      <AgentCall
        accent={palette.cyan}
        observed="Blue worker idle · tree node visible"
        action={'{"task":"gather","unit":"blue_0","target":"blue_tree_0"}'}
        receipt="accepted · gathering task started"
      />
    </Sequence>
    <Sequence from={505} durationInFrames={210}>
      <AgentCall
        accent={palette.coral}
        observed="Red line broken · enemy stronghold exposed"
        action={'{"task":"attack","target":"red_town_hall","units":2}'}
        receipt="accepted · damage resolved by Godot"
      />
    </Sequence>
    <Sequence from={690} durationInFrames={150}>
      <ScorePanel
        accent={palette.cyan}
        title="AUTHORITY RESULT"
        winner="Blue Command wins"
        metrics={[
          ['6', 'deposits'],
          ['3', 'knockouts'],
          ['2', 'survivors'],
        ]}
      />
    </Sequence>
  </AbsoluteFill>
);

const CrossroadsScene = () => (
  <AbsoluteFill style={{background: palette.bg, color: palette.text}}>
    <GameplayVideo src="crossroads-highlight.mp4" trimBefore={0} playbackRate={3.2} />
    <AbsoluteFill style={{background: 'linear-gradient(180deg, rgba(3,8,12,0.45), transparent 26%, transparent 72%, rgba(3,8,12,0.42))'}} />
    <GameLabel index="03" title="Crossroads Conquest" capability="Partial information · timing · multi-agent pressure" accent={palette.purple} speed="3.2× PLAYBACK" />
    <VerificationRibbon />
    <Sequence from={190} durationInFrames={215}>
      <AgentCall
        accent={palette.purple}
        observed="Sol and Terra committed to the eastern front"
        action={'{"type":"Think","intent":"hold_fire"}'}
        receipt="accepted · Luna keeps position"
      />
    </Sequence>
    <Sequence from={460} durationInFrames={235}>
      <AgentCall
        accent={palette.green}
        observed="Terra eliminated · Sol stronghold exposed"
        action={'{"type":"Attack","target":"core_sol","unit_count":4}'}
        receipt="accepted · Luna strikes in round 28"
      />
    </Sequence>
    <Sequence from={675} durationInFrames={165}>
      <ScorePanel
        accent={palette.purple}
        title="FINAL PLACEMENT"
        winner="Luna takes the Crossroads"
        metrics={[
          ['1st', 'Luna'],
          ['2nd', 'Sol'],
          ['3rd', 'Terra'],
        ]}
        note="2 deterministic runs · 0 rejected orders"
      />
    </Sequence>
  </AbsoluteFill>
);

const SoloScene = () => (
  <AbsoluteFill style={{background: palette.bg, color: palette.text}}>
    <Sequence from={0} durationInFrames={135}>
      <GameplayVideo src="solo-construction.mp4" trimBefore={4 * FPS} playbackRate={5.2} />
    </Sequence>
    <Sequence from={135} durationInFrames={135}>
      <GameplayVideo src="solo-construction.mp4" trimBefore={31 * FPS} playbackRate={5.2} />
    </Sequence>
    <Sequence from={270} durationInFrames={135}>
      <GameplayVideo src="solo-construction.mp4" trimBefore={62 * FPS} playbackRate={5.2} />
    </Sequence>
    <Sequence from={405} durationInFrames={135}>
      <GameplayVideo src="solo-construction.mp4" trimBefore={94 * FPS} playbackRate={5.8} />
    </Sequence>
    <AbsoluteFill style={{background: 'linear-gradient(180deg, rgba(3,8,12,0.48), transparent 26%, transparent 70%, rgba(3,8,12,0.48))'}} />
    <GameLabel index="+" title="Solo Campaign" capability="Turn · walk · gather · carry · deposit · build" accent={palette.mint} speed="5× PLAYBACK" />
    <Sequence from={100} durationInFrames={220}>
      <AgentCall
        accent={palette.mint}
        observed="Resource available · relay needs materials"
        action={'{"task":"gather_materials"}'}
        receipt="resource gathered · inventory updated"
      />
    </Sequence>
    <Sequence from={335} durationInFrames={205}>
      <AgentCall
        accent={palette.amber}
        observed="Build pad ready · delivered materials available"
        action={'{"task":"build_barricade"}'}
        receipt="construction complete · episode succeeded"
      />
    </Sequence>
  </AbsoluteFill>
);

const PortalSlide = ({src, label, copy}: {src: string; label: string; copy: string}) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{background: palette.bg, color: palette.text}}>
      <Img
        src={staticFile(src)}
        style={{
          width: '100%',
          height: '100%',
          objectFit: 'cover',
          filter: 'brightness(1.28) contrast(1.05)',
          scale: interpolate(frame, [0, 150], [1, 1.025], {
            extrapolateRight: 'clamp',
            easing: Easing.bezier(0.16, 1, 0.3, 1),
          }),
        }}
      />
      <AbsoluteFill style={{background: 'linear-gradient(90deg, rgba(3,8,12,0.78), transparent 42%, transparent 80%, rgba(3,8,12,0.22))'}} />
      <div
        style={{
          position: 'absolute',
          left: 58,
          bottom: 64,
          zIndex: 15,
          width: 680,
          padding: '22px 24px',
          borderRadius: 20,
          border: `1px solid ${palette.line}`,
          background: palette.panelStrong,
          opacity: fade(frame),
          translate: `0 ${rise(frame)}px`,
        }}
      >
        <div style={{color: palette.amber, fontSize: 16, fontWeight: 850, letterSpacing: 3.1}}>{label}</div>
        <div style={{fontSize: 26, lineHeight: 1.35, fontWeight: 650, marginTop: 10}}>{copy}</div>
      </div>
    </AbsoluteFill>
  );
};

const PortalScene = () => (
  <AbsoluteFill style={{background: palette.bg, color: palette.text}}>
    <Sequence from={0} durationInFrames={150}>
      <PortalSlide src="portal-run.png" label="RUN" copy="Watch the authority-verified broadcast." />
    </Sequence>
    <Sequence from={150} durationInFrames={150}>
      <PortalSlide src="portal-timeline.png" label="TIMELINE" copy="Trace economy, combat, and completion events." />
    </Sequence>
    <Sequence from={300} durationInFrames={150}>
      <PortalSlide src="portal-result.png" label="RESULT" copy="See the winner and exact terminal condition." />
    </Sequence>
    <Sequence from={450} durationInFrames={150}>
      <PortalSlide src="portal-evaluation.png" label="EVALUATION" copy="Connect performance metrics to world events." />
    </Sequence>
    <Sequence from={600} durationInFrames={150}>
      <PortalSlide src="portal-replay.png" label="REPLAY" copy="Verify the manifest, replay, final state, and video." />
    </Sequence>
    <Brand section="CONTROLLER LAB" />
  </AbsoluteFill>
);

const FinalScene = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{background: palette.bg, color: palette.text}}>
      <GameplayVideo src="crossroads-highlight.mp4" trimBefore={62 * FPS} playbackRate={1.7} darken={0.72} />
      <AbsoluteFill style={{background: 'radial-gradient(circle at 70% 50%, rgba(74,143,151,0.2), rgba(3,8,12,0.88) 65%)'}} />
      <div style={{position: 'absolute', left: 74, right: 74, top: 90, zIndex: 10}}>
        <div style={{color: palette.mint, fontSize: 18, fontWeight: 850, letterSpacing: 4}}>
          AUTHORITY-DERIVED RESULTS
        </div>
        <div style={{display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 16, marginTop: 28}}>
          {[
            ['LABYRINTH', 'Sol · 44.8s', '93.75% path efficiency', palette.amber],
            ['MINI RTS', 'Blue Command · win', '3 knockouts · 2 survivors', palette.cyan],
            ['CROSSROADS', 'Luna · 1st place', 'Round 28 decisive strike', palette.purple],
          ].map(([label, result, detail, accent], index) => {
            const reveal = interpolate(frame, [index * 16, index * 16 + 20], [0, 1], {
              extrapolateLeft: 'clamp',
              extrapolateRight: 'clamp',
            });
            return (
              <div
                key={label}
                style={{
                  minHeight: 190,
                  padding: '24px 26px',
                  borderRadius: 22,
                  border: `1px solid ${accent}77`,
                  background: palette.panelStrong,
                  opacity: reveal,
                  translate: `0 ${interpolate(reveal, [0, 1], [28, 0])}px`,
                }}
              >
                <div style={{color: accent, fontSize: 15, fontWeight: 850, letterSpacing: 3}}>{label}</div>
                <div style={{fontSize: 31, fontWeight: 850, marginTop: 20}}>{result}</div>
                <div style={{fontSize: 17, color: palette.muted, marginTop: 12}}>{detail}</div>
              </div>
            );
          })}
        </div>
        <div
          style={{
            marginTop: 45,
            textAlign: 'center',
            opacity: interpolate(frame, [160, 195], [0, 1], {
              extrapolateLeft: 'clamp',
              extrapolateRight: 'clamp',
            }),
          }}
        >
          <div style={{fontSize: 74, lineHeight: 1.05, fontWeight: 900, letterSpacing: -2.8}}>
            PUT INTELLIGENCE IN A WORLD
          </div>
          <div style={{fontSize: 74, lineHeight: 1.05, fontWeight: 900, letterSpacing: -2.8, color: palette.mint}}>
            WHERE ACTIONS HAVE CONSEQUENCES.
          </div>
          <div style={{fontSize: 28, color: palette.text, marginTop: 28, fontWeight: 700}}>
            WorldEval · Evaluate what AI does. Not only what it says.
          </div>
        </div>
      </div>
    </AbsoluteFill>
  );
};

export const WorldEvalHackathonDemo = () => (
  <AbsoluteFill
    style={{
      background: palette.bg,
      color: palette.text,
      fontFamily: 'Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, sans-serif',
      overflow: 'hidden',
    }}
  >
    <Sequence name="Cold open" from={0} durationInFrames={240}>
      <ColdOpen />
    </Sequence>
    <Sequence name="WorldEval introduction" from={240} durationInFrames={540}>
      <Introduction />
    </Sequence>
    <Sequence name="Agent call pipeline" from={780} durationInFrames={480}>
      <CallPipeline />
    </Sequence>
    <Sequence name="Labyrinth Run" from={1260} durationInFrames={660}>
      <LabyrinthScene />
    </Sequence>
    <Sequence name="Mini RTS" from={1920} durationInFrames={840}>
      <RtsScene />
    </Sequence>
    <Sequence name="Crossroads Conquest" from={2760} durationInFrames={840}>
      <CrossroadsScene />
    </Sequence>
    <Sequence name="Solo campaign" from={3600} durationInFrames={540}>
      <SoloScene />
    </Sequence>
    <Sequence name="Controller Lab" from={4140} durationInFrames={750}>
      <PortalScene />
    </Sequence>
    <Sequence name="Final results and close" from={4890} durationInFrames={510}>
      <FinalScene />
    </Sequence>
  </AbsoluteFill>
);
