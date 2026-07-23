import {
  AbsoluteFill,
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';

export type WorldArenaIntroProps = {
  title: string;
  subtitle: string;
  roundCount: number;
};

const factionColors = ['#FFB84A', '#6EE7C2', '#A99BFF'] as const;

export const WorldArenaIntro = ({
  title,
  subtitle,
  roundCount,
}: WorldArenaIntroProps) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const entrance = spring({
    frame,
    fps,
    config: {damping: 18, mass: 0.85, stiffness: 95},
  });
  const fadeOut = interpolate(frame, [205, 239], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const orbit = frame * 0.28;

  return (
    <AbsoluteFill
      style={{
        overflow: 'hidden',
        color: '#F5F8FF',
        fontFamily:
          'Inter, ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
        background:
          'radial-gradient(circle at 50% 42%, #18374A 0%, #091923 43%, #040A10 100%)',
        opacity: fadeOut,
      }}
    >
      <AbsoluteFill
        style={{
          backgroundImage:
            'linear-gradient(rgba(117, 187, 214, 0.055) 1px, transparent 1px), linear-gradient(90deg, rgba(117, 187, 214, 0.055) 1px, transparent 1px)',
          backgroundSize: '76px 76px',
          transform: `perspective(850px) rotateX(58deg) translateY(${260 + orbit}px) scale(1.55)`,
          transformOrigin: 'center center',
          opacity: 0.65,
        }}
      />

      <AbsoluteFill
        style={{
          alignItems: 'center',
          justifyContent: 'center',
          transform: `translateY(${interpolate(entrance, [0, 1], [55, 0])}px)`,
          opacity: entrance,
        }}
      >
        <div
          style={{
            display: 'flex',
            gap: 18,
            marginBottom: 44,
          }}
        >
          {factionColors.map((color, index) => {
            const scale = spring({
              frame: frame - index * 7,
              fps,
              config: {damping: 14, stiffness: 115},
            });
            return (
              <div
                key={color}
                style={{
                  width: 19,
                  height: 19,
                  backgroundColor: color,
                  transform: `rotate(45deg) scale(${scale})`,
                  boxShadow: `0 0 28px ${color}`,
                }}
              />
            );
          })}
        </div>

        <div
          style={{
            fontSize: 118,
            fontWeight: 760,
            letterSpacing: '0.15em',
            lineHeight: 1,
            textAlign: 'center',
            textShadow: '0 12px 50px rgba(0, 0, 0, 0.48)',
          }}
        >
          {title}
        </div>
        <div
          style={{
            width: 900,
            marginTop: 38,
            color: '#AFC2CE',
            fontSize: 30,
            fontWeight: 430,
            letterSpacing: '0.035em',
            lineHeight: 1.45,
            textAlign: 'center',
          }}
        >
          {subtitle}
        </div>
        <div
          style={{
            marginTop: 54,
            color: '#6EE7C2',
            fontSize: 19,
            fontWeight: 680,
            letterSpacing: '0.18em',
          }}
        >
          {roundCount} SIMULTANEOUS ROUNDS
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
