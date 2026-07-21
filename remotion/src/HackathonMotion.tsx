import type {CSSProperties, ReactNode} from 'react';
import {AbsoluteFill, Easing, interpolate, useCurrentFrame, useVideoConfig} from 'remotion';

/**
 * Small, composable motion pieces for the WorldArena hackathon cuts.
 *
 * These deliberately use generic editorial-cinema conventions (matte, stage,
 * route, and instrumentation) rather than reproducing another brand's layout.
 */
export const arenaPalette = {
  matte: '#071016',
  matteLift: '#0c1b23',
  paper: '#f1f4ee',
  ink: '#102128',
  mutedInk: '#617075',
  cyan: '#68ead6',
  cyanDeep: '#1e9e99',
  grid: 'rgba(104, 234, 214, 0.18)',
};

const easeOut = Easing.bezier(0.16, 1, 0.3, 1);

export const ArenaMatte = ({children}: {children?: ReactNode}) => {
  const frame = useCurrentFrame();
  const {width, height} = useVideoConfig();
  const drift = interpolate(frame % 360, [0, 360], [-32, 32]);

  return (
    <AbsoluteFill
      style={{
        background: `radial-gradient(circle at ${width * 0.76 + drift}px ${height * 0.18}px, #173c3d 0, transparent 29%), linear-gradient(130deg, ${arenaPalette.matte}, ${arenaPalette.matteLift})`,
        overflow: 'hidden',
      }}
    >
      <div
        style={{
          position: 'absolute',
          inset: 0,
          opacity: 0.42,
          backgroundImage:
            'linear-gradient(rgba(154, 255, 244, 0.075) 1px, transparent 1px), linear-gradient(90deg, rgba(154, 255, 244, 0.075) 1px, transparent 1px)',
          backgroundSize: '48px 48px',
          backgroundPosition: `${drift}px ${-drift}px`,
          maskImage: 'linear-gradient(115deg, rgba(0,0,0,0.85), transparent 78%)',
        }}
      />
      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          bottom: 0,
          height: 210,
          background: 'linear-gradient(transparent, rgba(1, 6, 9, 0.72))',
        }}
      />
      {children}
    </AbsoluteFill>
  );
};

export const StageCard = ({
  children,
  style,
  tone = 'paper',
}: {
  children?: ReactNode;
  style?: CSSProperties;
  tone?: 'paper' | 'dark';
}) => {
  const frame = useCurrentFrame();
  const enter = interpolate(frame, [0, 22], [0.96, 1], {
    extrapolateRight: 'clamp',
    easing: easeOut,
  });

  return (
    <div
      style={{
        position: 'absolute',
        borderRadius: 34,
        padding: 42,
        scale: enter,
        background: tone === 'paper' ? arenaPalette.paper : 'rgba(6, 20, 27, 0.88)',
        color: tone === 'paper' ? arenaPalette.ink : arenaPalette.paper,
        boxShadow: '0 30px 90px rgba(0, 0, 0, 0.32), inset 0 1px rgba(255,255,255,0.32)',
        ...style,
      }}
    >
      {children}
    </div>
  );
};

export const KineticTitle = ({
  children,
  size = 118,
  delay = 0,
  style,
}: {
  children: ReactNode;
  size?: number;
  delay?: number;
  style?: CSSProperties;
}) => {
  const frame = useCurrentFrame();
  const localFrame = Math.max(0, frame - delay);

  return (
    <div
      style={{
        opacity: interpolate(localFrame, [0, 12], [0, 1], {
          extrapolateRight: 'clamp',
          easing: easeOut,
        }),
        translate: `0 ${interpolate(localFrame, [0, 20], [42, 0], {extrapolateRight: 'clamp', easing: easeOut})}px`,
        filter: `blur(${interpolate(localFrame, [0, 14], [10, 0], {extrapolateRight: 'clamp'})}px)`,
        fontSize: size,
        fontWeight: 850,
        lineHeight: 0.91,
        letterSpacing: '-0.075em',
        textWrap: 'balance',
        ...style,
      }}
    >
      {children}
    </div>
  );
};

export const CornerMetadata = ({
  left = 'WORLDARENA / 2026',
  right = 'EVALUATION ENVIRONMENT',
  dark = false,
}: {
  left?: string;
  right?: string;
  dark?: boolean;
}) => {
  const frame = useCurrentFrame();
  const color = dark ? 'rgba(240,244,238,0.76)' : arenaPalette.mutedInk;

  return (
    <>
      <div style={{position: 'absolute', left: 44, top: 35, color, fontSize: 15, fontWeight: 800, letterSpacing: 1.7}}>{left}</div>
      <div style={{position: 'absolute', right: 44, top: 35, color, fontSize: 15, fontWeight: 800, letterSpacing: 1.7, textAlign: 'right'}}>{right}</div>
      <div style={{position: 'absolute', right: 44, bottom: 34, color, fontSize: 14, fontVariantNumeric: 'tabular-nums', letterSpacing: 1.35}}>
        T+{String(Math.floor(frame / 30)).padStart(2, '0')}.{String((frame % 30) * 3).padStart(2, '0')}
      </div>
    </>
  );
};

export const PulseGrid = ({opacity = 1}: {opacity?: number}) => {
  const frame = useCurrentFrame();
  const sweep = interpolate(frame % 150, [0, 150], [-260, 2080]);

  return (
    <>
      <div
        style={{
          position: 'absolute',
          inset: 0,
          opacity: opacity * 0.4,
          backgroundImage:
            'linear-gradient(rgba(104,234,214,0.33) 1px, transparent 1px), linear-gradient(90deg, rgba(104,234,214,0.33) 1px, transparent 1px)',
          backgroundSize: '54px 54px',
          maskImage: 'linear-gradient(145deg, rgba(0,0,0,0.75), transparent 70%)',
        }}
      />
      <div
        style={{
          position: 'absolute',
          top: 0,
          bottom: 0,
          left: sweep,
          width: 3,
          opacity,
          background: arenaPalette.cyan,
          boxShadow: '0 0 26px 9px rgba(104,234,214,0.48)',
        }}
      />
    </>
  );
};

export const RoutePulse = ({
  points,
  stroke = arenaPalette.cyan,
  width = 7,
}: {
  points: Array<[number, number]>;
  stroke?: string;
  width?: number;
}) => {
  const frame = useCurrentFrame();
  const {width: canvasWidth, height: canvasHeight} = useVideoConfig();
  const path = points.map(([x, y], index) => `${index === 0 ? 'M' : 'L'} ${x} ${y}`).join(' ');
  const reveal = interpolate(frame, [0, 46], [0, 1], {extrapolateRight: 'clamp', easing: easeOut});
  const dash = 3400;
  const dotIndex = Math.min(points.length - 1, Math.floor(reveal * (points.length - 1)));
  const [dotX, dotY] = points[dotIndex] ?? [0, 0];

  return (
    <svg
      width={canvasWidth}
      height={canvasHeight}
      viewBox={`0 0 ${canvasWidth} ${canvasHeight}`}
      style={{position: 'absolute', inset: 0, overflow: 'visible', pointerEvents: 'none'}}
    >
      <path d={path} fill="none" stroke="rgba(104,234,214,0.2)" strokeWidth={width} strokeLinecap="round" strokeLinejoin="round" />
      <path
        d={path}
        fill="none"
        stroke={stroke}
        strokeWidth={width}
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeDasharray={dash}
        strokeDashoffset={dash * (1 - reveal)}
      />
      <circle cx={dotX} cy={dotY} r={width * 1.85} fill={stroke} opacity={0.16} />
      <circle cx={dotX} cy={dotY} r={width * 0.72} fill={arenaPalette.paper} />
    </svg>
  );
};
