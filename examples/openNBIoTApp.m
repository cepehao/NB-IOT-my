function app=openNBIoTApp(dialogs,options)
%OPENNBIOTAPP Open the bounded local Static-mode user interface.
%   Открывает GUI симулятора.
% Optional DIALOGS supplies callbacks for automated UI checks. Optional
% OPTIONS forwards an execution profile and controller configuration.
root=fileparts(fileparts(mfilename('fullpath'))); addpath(root); setupProject();
addpath(fullfile(root,'apps'));
if nargin<1, dialogs=[]; end
if nargin<2, options=struct(); end
app=NBIoTApp(dialogs,options);
end
