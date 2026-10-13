/** Catálogo de los 8 juegos (mismo origen que runtime/src/data/games.json). */

export type Engine = 'ka-mfc' | 'aces' | 'peewee';

export interface GameInfo {
  id: string;
  order: number;
  name: string;
  age: string;
  engine: Engine;
  isoFile: string;
  isoSize: number;
  /** Archivo que identifica el disco. */
  keyFile: string;
  /** Carpeta principal de recursos dentro del disco (para la galería). */
  resourceDirs: string[];
  /** Estado del remaster para este juego. */
  remaster: 'viewer' | 'gallery' | 'playable';
}

export const GAMES: GameInfo[] = [
  { id: 'TODDLER', order: 1, name: 'Educación Infantil – Primeros Pasos', age: '2 a 3 años', engine: 'aces', isoFile: 'Trampolín Educación Infantil - Primeros Pasos.iso', isoSize: 255424512, keyFile: 'SUPPORT/W32/ACES.EXE', resourceDirs: ['TODDLER'], remaster: 'viewer' },
  { id: 'PRSCHOOL', order: 2, name: 'Educación Infantil – 1° Ciclo', age: '3 a 4 años', engine: 'aces', isoFile: 'Trampolín Educación Infantil - 1° Ciclo.iso', isoSize: 140679168, keyFile: 'SUPPORT/W32/ACES.EXE', resourceDirs: ['PRSCHOOL'], remaster: 'viewer' },
  { id: 'PRE_K', order: 3, name: 'Educación Infantil – Primera Infancia', age: '4 años', engine: 'peewee', isoFile: 'Trampolín Educación Infantil - Primera Infancia.iso', isoSize: 153976832, keyFile: 'SUPPORT/CMN/PRE_K.EXE', resourceDirs: ['CUADERNO'], remaster: 'viewer' },
  { id: 'KG', order: 4, name: 'Educación Infantil – 2° Ciclo', age: '5 años', engine: 'ka-mfc', isoFile: 'Trampolín Educación Infantil - 2° Ciclo.iso', isoSize: 94410752, keyFile: 'SUPPORT/W32/KG.EXE', resourceDirs: ['KG/32BIT'], remaster: 'gallery' },
  { id: 'FG', order: 5, name: 'Educación Primaria – 1° Ciclo', age: '6 a 7 años', engine: 'ka-mfc', isoFile: 'Trampolin - 1° Ciclo.iso', isoSize: 416952320, keyFile: 'SUPPORT/W32/FG.EXE', resourceDirs: ['FG/32BIT'], remaster: 'gallery' },
  { id: '2G', order: 6, name: 'Educación Primaria – 2° Ciclo', age: '7 a 8 años', engine: 'ka-mfc', isoFile: 'Trampolin - 2° Ciclo.iso', isoSize: 300566528, keyFile: 'SUPPORT/W32/2G.EXE', resourceDirs: ['2G/32BIT'], remaster: 'gallery' },
  { id: '3G', order: 7, name: 'Educación Primaria – 5° Curso', age: '8 a 9 años', engine: 'ka-mfc', isoFile: 'Trampolin - 5° Curso.iso', isoSize: 494227456, keyFile: 'SUPPORT/W32/3G.EXE', resourceDirs: ['3G'], remaster: 'gallery' },
  { id: '4G', order: 8, name: 'Educación Primaria – 6° Curso', age: '9 a 10 años', engine: 'peewee', isoFile: 'Trampolin - 6° Curso.iso', isoSize: 524453888, keyFile: 'SUPPORT/CMN/4G.EXE', resourceDirs: ['MOVIES'], remaster: 'viewer' },
];

export function gameById(id: string): GameInfo | undefined {
  return GAMES.find((g) => g.id === id);
}

export const ENGINE_NAMES: Record<Engine, string> = {
  'ka-mfc': 'Motor KA "Broadway" (1996-98)',
  aces: 'Motor ACES "Accomplish" (1995-96)',
  peewee: 'Motor PEEWEE (1998)',
};
