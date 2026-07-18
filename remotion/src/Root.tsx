import {Composition} from 'remotion';
import {
  WorldArenaIntro,
  type WorldArenaIntroProps,
} from './WorldArenaIntro';

const defaultIntroProps: WorldArenaIntroProps = {
  title: 'WORLD ARENA',
  subtitle: 'Three minds. One world. Every decision has consequences.',
  roundCount: 40,
};

export const RemotionRoot = () => {
  return (
    <Composition
      id="WorldArenaIntro"
      component={WorldArenaIntro}
      durationInFrames={240}
      fps={30}
      width={1920}
      height={1080}
      defaultProps={defaultIntroProps}
    />
  );
};
