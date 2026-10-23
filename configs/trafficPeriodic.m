function cfg=trafficPeriodic()
%   Конфигурация с периодическим трафиком (ТЗ §11.1).
cfg=nbiot.config.defaultConfig(); cfg.traffic.kind='periodic'; cfg=nbiot.config.validateConfig(cfg);
end
