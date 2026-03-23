abstract interface class IServiceRegistry {
  bool isRegistered<T extends Object>();
  T resolve<T extends Object>({String? dependencyName});
  T? maybeResolve<T extends Object>();
  void registerSingleton<T extends Object>(T instance);
  void registerLazySingleton<T extends Object>(T Function() factory);
  void unregister<T extends Object>();
}
