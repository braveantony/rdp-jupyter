    '--no-browser',
    '--expose-app-in-browser',
    `--ServerApp.port={port}`,
    // use our token rather than any pre-configured password
    '--ServerApp.password=""',
    `--ServerApp.token="{token}"`,
    '--LabApp.quit_button=False'
];
