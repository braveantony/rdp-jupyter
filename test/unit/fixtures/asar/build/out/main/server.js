                shell: isWin ? 'cmd.exe' : '/bin/bash',
                env: {
                    ...process.env,
                    JUPYTER_CONFIG_DIR: process.env.JLAB_DESKTOP_CONFIG_DIR || (0, utils_1.getUserDataDir)(),
                    JUPYTERLAB_WORKSPACES_DIR: process.env.JLAB_DESKTOP_WORKSPACES_DIR || jlabWorkspacesDir,
                    ...serverEnvVars
                }
            };
