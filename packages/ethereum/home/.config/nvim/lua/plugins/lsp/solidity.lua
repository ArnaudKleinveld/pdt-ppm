return {
  solidity_ls_nomicfoundation = {
    cmd = { 'nomicfoundation-solidity-language-server', '--stdio' },
    filetypes = { 'solidity' },
    root_dir = function(fname)
      return require('lspconfig.util').root_pattern('foundry.toml', 'hardhat.config.*', '.git')(fname)
    end,
    settings = {
      solidity = {
        includePath = '',
        remappings = {},
      },
    },
  },
}
