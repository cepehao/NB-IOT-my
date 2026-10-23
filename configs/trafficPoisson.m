function cfg=trafficPoisson()
cfg=nbiot.config.defaultConfig(); cfg.traffic.kind='poisson'; cfg=nbiot.config.validateConfig(cfg);
end
