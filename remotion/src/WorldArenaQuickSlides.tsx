import {
  AbsoluteFill,
  Easing,
  Sequence,
  Video,
  interpolate,
  staticFile,
  useCurrentFrame,
} from 'remotion';
import {CornerMetadata, KineticTitle, PulseGrid, RoutePulse, StageCard, arenaPalette} from './HackathonMotion';

const gameplay = staticFile('worldarena-gameplay.mp4');
const paper = arenaPalette.paper;
const ink = arenaPalette.ink;
const cyan = arenaPalette.cyan;

const Slide = ({
  number,
  kicker,
  title,
  detail,
  route,
}: {
  number: string;
  kicker: string;
  title: string;
  detail: string;
  route: Array<[number, number]>;
}) => {
  const frame = useCurrentFrame();
  const cardScale = interpolate(frame, [0, 22], [0.92, 1], {
    extrapolateRight: 'clamp',
    easing: Easing.bezier(0.16, 1, 0.3, 1),
  });
  const gameplayScale = interpolate(frame, [0, 180], [1.14, 1.04], {extrapolateRight: 'clamp'});
  const detailOpacity = interpolate(frame, [34, 54, 155, 174], [0, 1, 1, 0], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});

  return (
    <AbsoluteFill style={{background: arenaPalette.matte, color: paper, overflow: 'hidden', fontFamily: 'Inter, ui-sans-serif, system-ui, sans-serif'}}>
      <Video src={gameplay} muted loop style={{width: '100%', height: '100%', objectFit: 'cover', scale: gameplayScale, opacity: 0.76}} />
      <AbsoluteFill style={{background: 'linear-gradient(90deg, rgba(3,12,17,0.94), rgba(3,12,17,0.56) 48%, rgba(3,12,17,0.1))'}} />
      <PulseGrid opacity={0.3} />
      <CornerMetadata left={`WORLDARENA / ${number}`} right="EMBODIED EVALUATION" dark />
      <StageCard tone="paper" style={{left: 76, top: 158, width: 910, minHeight: 650, scale: cardScale}}>
        <div style={{color: '#657579', fontWeight: 850, fontSize: 18, letterSpacing: 2.8}}>{kicker}</div>
        <KineticTitle size={104} delay={9} style={{color: ink, marginTop: 31, maxWidth: 760}}>{title}</KineticTitle>
        <div style={{opacity: detailOpacity, color: '#516166', fontWeight: 620, fontSize: 29, lineHeight: 1.27, letterSpacing: '-0.025em', marginTop: 36, maxWidth: 720}}>{detail}</div>
        <div style={{position: 'absolute', left: 42, bottom: 42, color: '#168c88', fontWeight: 850, fontSize: 16, letterSpacing: 1.8}}>WORLD → ACTION → EVIDENCE</div>
      </StageCard>
      <div style={{position: 'absolute', right: 68, bottom: 43, color: paper, fontSize: 15, fontWeight: 800, letterSpacing: 1.5}}><span style={{color: cyan}}>●</span> LIVE WORLD STATE</div>
      <RoutePulse points={route} />
    </AbsoluteFill>
  );
};

export const WorldArenaQuickSlides = () => (
  <AbsoluteFill>
    <Sequence name="Physical dependencies" from={0} durationInFrames={180} premountFor={30}>
      <Slide number="01" kicker="THE QUESTION" title="Text is not the world." detail="A good-sounding plan can still fail when the car, resource, or objective is somewhere else." route={[[1080, 870], [1320, 690], [1610, 790], [1790, 585]]} />
    </Sequence>
    <Sequence name="Embodied control" from={180} durationInFrames={180} premountFor={30}>
      <Slide number="02" kicker="THE METHOD" title="See. Act. Adapt." detail="Models receive a participant view, choose bounded inputs, and meet continuous simulation consequences." route={[[1020, 800], [1280, 650], [1480, 825], [1760, 570]]} />
    </Sequence>
    <Sequence name="Replayable evidence" from={360} durationInFrames={180} premountFor={30}>
      <Slide number="03" kicker="THE PROOF" title="Fair games. Replayable evidence." detail="WorldArena makes outcomes inspectable—with shared rules, scoped views, and receipts for what happened." route={[[1100, 850], [1240, 720], [1510, 680], [1740, 510]]} />
    </Sequence>
  </AbsoluteFill>
);
