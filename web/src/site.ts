const github = 'https://github.com/mukhtharcm/sidemesh';

/** Destinations shared by the layout and pages. */
export const links = {
  github,
  readme: `${github}#readme`,
  issues: `${github}/issues`,
  securityAdvisory: `${github}/security/advisories/new`,
  releases: `${github}/releases`,
  webApp: 'https://app.sidemesh.com',
  discord: '/discord',
  testflight: '/testflight',
  discordInvite: 'https://discord.gg/URvvnN7Dv',
  testflightJoin: 'https://testflight.apple.com/join/UZ6FTc9r',
} as const;
