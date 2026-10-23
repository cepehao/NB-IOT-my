function cfg=trafficPeriodic()
cfg=nbiot.config.defaultConfig(); cfg.traffic.kind='periodic'; cfg=nbiot.config.validateConfig(cfg);
end
