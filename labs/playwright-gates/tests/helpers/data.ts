// Expected values come straight from the dataset the API serves.
import projects from '../../../../shared/server/data/projects.json';

export function maturityCount(maturity: string): number {
  return projects.filter((p) => p.maturity === maturity).length;
}

export const mostStarred = [...projects].sort((a, b) => b.stars - a.stars)[0];
